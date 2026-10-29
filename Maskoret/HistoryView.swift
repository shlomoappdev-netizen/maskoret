import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject private var store: Store
    @State private var selected: MonthRecord?
    @State private var showSaveMonth = false

    private var actuals: [Double] { store.history.compactMap { $0.actualNet } }

    /// Last 12 saved months, oldest first (for the chart).
    private var chartRecords: [MonthRecord] {
        Array(store.sortedHistory.prefix(12).reversed())
    }

    private var averageNet: Double {
        if !actuals.isEmpty { return actuals.reduce(0, +) / Double(actuals.count) }
        guard !store.history.isEmpty else { return 0 }
        return store.history.reduce(0) { $0 + $1.budget.net } / Double(store.history.count)
    }

    /// What was left at the end of each saved month — the same number as "נשאר בסוף החודש" in the summary.
    private var results: [UUID: MonthPicture] {
        Dictionary(uniqueKeysWithValues: store.history.map { ($0.id, store.monthResult($0)) })
    }

    private func averageRemaining(_ results: [UUID: MonthPicture]) -> Double {
        guard !results.isEmpty else { return 0 }
        return results.values.reduce(0) { $0 + $1.remaining } / Double(results.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    ContentUnavailableView {
                        Label("אין חודשים רשומים", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("כשמגיע התלוש — רשום כמה נטו נכנס בפועל. התחזית תתבסס על הממוצע של החודשים האחרונים.")
                    } actions: {
                        Button("רשום חודש") { showSaveMonth = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    let results = self.results
                    ScrollView {
                        VStack(spacing: 16) {
                            PageBar(title: "חודשים", subtitle: "הנטו שנכנס בפועל בכל חודש, מול ההערכה") {
                                Button {
                                    showSaveMonth = true
                                } label: {
                                    Label("רשום חודש", systemImage: "calendar.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.horizontal, -20)
                            AdaptiveStack {
                                Card {
                                    Text("מגמה — 12 החודשים האחרונים")
                                        .font(.headline)
                                    HistoryChart(records: chartRecords, remaining: { results[$0.id]?.remaining ?? 0 })
                                        .frame(height: 240)
                                }
                                VStack(spacing: 12) {
                                    StatTile(title: actuals.isEmpty ? "נטו ממוצע (משוער)" : "נטו ממוצע בפועל", value: Fmt.moneyRounded(averageNet), icon: "banknote")
                                    StatTile(title: "נשאר בממוצע בסוף חודש", value: Fmt.moneyRounded(averageRemaining(results)), icon: "chart.line.uptrend.xyaxis")
                                    StatTile(title: "חודשים שמורים", value: "\(store.history.count)", icon: "calendar")
                                }
                                .regularWidth(220)
                            }

                            Card {
                                Text("חודשים")
                                    .font(.headline)
                                ForEach(store.sortedHistory) { record in
                                    Button {
                                        selected = record
                                    } label: {
                                        HistoryRow(record: record, remaining: results[record.id]?.remaining ?? record.budget.remaining)
                                    }
                                    .buttonStyle(.plain)
                                    .rowMenu(onEdit: { selected = record }) {
                                        store.deleteRecord(record)
                                    }
                                    if record.id != store.sortedHistory.last?.id {
                                        Divider()
                                    }
                                }
                                Text("״נשאר״ = מה שנשאר בעו״ש בסוף החודש — אותו חישוב כמו ״נשאר בסוף החודש״ בסיכום: הנטו (בפועל אם נרשם, אחרת משוער), פחות הוצאות קבועות, רכישות תקופתיות, חיובי אשראי משתנים והעברות לחיסכון, ועם תנועות חד-פעמיות. לחיצה על חודש מציגה את הפירוט.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                }
            }
            .navigationTitle("חודשים")
            .sheet(isPresented: $showSaveMonth) {
                SaveMonthSheet()
                    .environmentObject(store)
            }
            .sheet(item: $selected) { record in
                RecordDetailView(record: record)
                    .environmentObject(store)
            }
        }
    }
}

struct HistoryChart: View {
    let records: [MonthRecord]
    let remaining: (MonthRecord) -> Double

    var body: some View {
        Chart {
            ForEach(records) { record in
                BarMark(
                    x: .value("חודש", record.shortTitle),
                    y: .value("סכום", record.actualNet ?? record.budget.net)
                )
                .foregroundStyle(by: .value("סוג", "נטו"))
                .position(by: .value("סוג", "נטו"))

                BarMark(
                    x: .value("חודש", record.shortTitle),
                    y: .value("סכום", remaining(record))
                )
                .foregroundStyle(by: .value("סוג", "נשאר בסוף החודש"))
                .position(by: .value("סוג", "נשאר בסוף החודש"))
            }
        }
        .chartForegroundStyleScale(["נטו": Color.blue, "נשאר בסוף החודש": Color.green])
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(verbatim: Fmt.compact(amount))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }
}

struct HistoryRow: View {
    let record: MonthRecord
    /// What was left at the end of the month (see `Store.monthResult`).
    let remaining: Double
    @Environment(\.isCompactWidth) private var compact

    var body: some View {
        if compact { compactBody } else { wideBody }
    }

    /// iPhone: the month on the right, the remaining money under it, and the details in one small line.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(record.title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(verbatim: "נשאר " + Fmt.moneyRounded(remaining))
                    .monospacedDigit()
                    .foregroundStyle(remaining >= 0 ? Color.green : Color.red)
            }
            Text(verbatim: "ברוטו " + Fmt.moneyRounded(record.budget.gross)
                 + (record.actualNet.map { " · בפועל " + Fmt.moneyRounded($0) } ?? "")
                 + " · משוער " + Fmt.moneyRounded(record.budget.net))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !record.note.isEmpty {
                Text(record.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var wideBody: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.body.weight(.medium))
                if !record.note.isEmpty {
                    Text(record.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(verbatim: "ברוטו " + Fmt.moneyRounded(record.budget.gross))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 130, alignment: .trailing)
            Text(verbatim: record.actualNet.map { "בפועל " + Fmt.moneyRounded($0) } ?? "—")
                .foregroundStyle(record.actualNet == nil ? Color.secondary : Color.primary)
                .monospacedDigit()
                .frame(width: 130, alignment: .trailing)
            Text(verbatim: "משוער " + Fmt.moneyRounded(record.budget.net))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 130, alignment: .trailing)
            Text(verbatim: "נשאר " + Fmt.moneyRounded(remaining))
                .monospacedDigit()
                .foregroundStyle(remaining >= 0 ? Color.green : Color.red)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct RecordDetailView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let record: MonthRecord

    @State private var confirmLoad = false
    @State private var confirmDelete = false

    var body: some View {
        SheetContainer(title: record.title, width: 520, onSave: nil) {
            if !record.note.isEmpty {
                Section("הערה") {
                    Text(record.note)
                }
            }

            Section {
                MonthBreakdown(picture: store.monthResult(record))
                    .padding(.vertical, 4)
            } header: {
                Text("מה נשאר בסוף החודש")
            } footer: {
                Text("אותו חישוב כמו בסיכום, עם ההכנסות, הניכויים וההוצאות הקבועות של החודש הזה, וחיובי האשראי והתנועות שלו.")
            }

            Section("מהברוטו לנטו (לפי התלוש של החודש)") {
                BudgetBreakdown(budget: record.budget, payslipOnly: true)
                    .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Button {
                        confirmLoad = true
                    } label: {
                        Label("טען כנתונים הנוכחיים", systemImage: "arrow.uturn.backward")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("מחק חודש", systemImage: "trash")
                    }
                }
            } footer: {
                Text("״טען״ מחליף את ההכנסות, הניכויים וההוצאות הנוכחיים בנתונים של החודש הזה.")
            }
        }
        .confirmationDialog("להחליף את הנתונים הנוכחיים?", isPresented: $confirmLoad) {
            Button("טען") {
                store.loadIntoCurrent(record)
                dismiss()
            }
            Button("ביטול", role: .cancel) {}
        }
        .confirmationDialog("למחוק את החודש?", isPresented: $confirmDelete) {
            Button("מחק", role: .destructive) {
                store.deleteRecord(record)
                dismiss()
            }
            Button("ביטול", role: .cancel) {}
        }
    }
}

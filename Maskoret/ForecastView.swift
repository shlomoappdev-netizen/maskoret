import SwiftUI
import Charts

struct ForecastView: View {
    @EnvironmentObject private var store: Store

    private var months: [ForecastMonth] { store.forecast() }
    private var settings: ForecastSettings { store.money.forecast }

    private var expected: (amount: Double, source: String) {
        MoneyCalc.expectedNet(budget: store.dashboard.budget, history: store.dashboard.history, settings: settings)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PageBar(title: "תחזית", subtitle: "לאן הכסף שלך הולך בחודשים הקרובים") {
                        Picker("טווח", selection: $store.money.forecast.months) {
                            Text(verbatim: "3 חודשים").tag(3)
                            Text(verbatim: "6 חודשים").tag(6)
                            Text(verbatim: "12 חודשים").tag(12)
                            Text(verbatim: "24 חודשים").tag(24)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, -20)

                    if let first = months.first, let last = months.last {
                        tiles(first: first, last: last)
                        chartCard
                        assumptionsCard
                        tableCard
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.window)
            .navigationTitle("תחזית")
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tiles(first: ForecastMonth, last: ForecastMonth) -> some View {
        let change = last.liquid - first.liquid
        let lowest = months.min { $0.checking < $1.checking }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            StatTile(
                title: "עו״ש + חיסכון בעוד \(last.index) חודשים",
                value: Fmt.moneyRounded(last.liquid),
                icon: "chart.line.uptrend.xyaxis"
            )
            StatTile(
                title: "שינוי בתקופה",
                value: (change >= 0 ? "+" : "−") + Fmt.moneyRounded(abs(change)),
                icon: change >= 0 ? "arrow.up.right" : "arrow.down.right"
            )
            StatTile(
                title: "עו״ש צפוי",
                value: Fmt.moneyRounded(last.checking),
                icon: "creditcard.fill"
            )
            StatTile(
                title: "חיסכון ופיקדונות צפויים",
                value: Fmt.moneyRounded(last.savings),
                icon: "lock.fill"
            )
            if let lowest {
                StatTile(
                    title: "נקודת השפל בעו״ש",
                    value: Fmt.moneyRounded(lowest.checking) + (lowest.index == 0 ? " (היום)" : " · " + lowest.shortLabel),
                    icon: lowest.checking < 0 ? "exclamationmark.triangle.fill" : "arrow.down.to.line"
                )
            }
            StatTile(
                title: "פנסיה צפויה",
                value: Fmt.moneyRounded(last.pension),
                icon: "umbrella.fill"
            )
        }
        if let lowest, lowest.checking < 0 {
            Label("לפי התחזית העו״ש ייכנס למינוס ב\(lowest.label). כדאי לבדוק הוצאות גדולות מתוכננות או להעביר כסף מהחיסכון.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let id = UUID()
        let month: Int
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        months.flatMap { m -> [Point] in
            let label = m.index == 0 ? "היום" : m.shortLabel
            var result = [
                Point(month: m.index, label: label, series: "עו״ש", value: m.checking),
                Point(month: m.index, label: label, series: "חיסכון ופיקדונות", value: m.savings),
                Point(month: m.index, label: label, series: "סה״כ", value: m.liquid)
            ]
            if store.money.accounts.contains(where: { $0.kind == .pension }) {
                result.append(Point(month: m.index, label: label, series: "פנסיה", value: m.pension))
            }
            return result
        }
    }

    private var chartCard: some View {
        Card {
            Text("התחזית חודש אחרי חודש")
                .font(.headline)
            Chart(points) { p in
                LineMark(
                    x: .value("חודש", p.label),
                    y: .value("סכום", p.value)
                )
                .foregroundStyle(by: .value("סדרה", p.series))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: p.series == "סה״כ" ? 3 : 2, dash: p.series == "פנסיה" ? [4, 4] : []))
                PointMark(
                    x: .value("חודש", p.label),
                    y: .value("סכום", p.value)
                )
                .foregroundStyle(by: .value("סדרה", p.series))
                .symbolSize(18)
            }
            .chartForegroundStyleScale([
                "עו״ש": Color.blue,
                "חיסכון ופיקדונות": Color.green,
                "סה״כ": Color.accentColor,
                "פנסיה": Color.purple
            ])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(verbatim: Fmt.compact(amount)) }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 280)
        }
    }

    // MARK: Assumptions

    private var assumptionsCard: some View {
        Card {
            HStack {
                Text("על מה התחזית מבוססת")
                    .font(.headline)
                Spacer()
                Picker("בסיס ההכנסה", selection: $store.money.forecast.basis) {
                    ForEach(IncomeBasis.allCases) { basis in
                        Text(basis.title).tag(basis)
                    }
                }
                .fixedSize()
            }
            if settings.basis == .manual {
                AmountField(title: "נטו חודשי צפוי", value: $store.money.forecast.manualNet)
                    .frame(maxWidth: 360)
            }
            let first = months.count > 1 ? months[1] : nil
            RateLine(title: "הכנסה נטו בחודש", value: Fmt.moneyRounded(expected.amount) + " — " + expected.source)
            RateLine(title: "הוצאות קבועות ורכישות תקופתיות", value: "−" + Fmt.moneyRounded((first?.spending ?? 0) - (first?.card ?? 0)))
            if let last = months.last, last.card > 0 {
                RateLine(title: "כרטיס אשראי — הוצאות משתנות", value: "−" + Fmt.moneyRounded(last.card) + (store.money.cardTransactions.isEmpty ? "" : " — ממוצע 3 החיובים האחרונים (חודש עם חיוב מיובא — לפי הקובץ)"))
            }
            RateLine(title: "העברות קבועות לחיסכון", value: Fmt.moneyRounded(first?.toSavings ?? 0))
            RateLine(title: "נשאר בעו״ש בכל חודש", value: Fmt.moneyRounded(expected.amount - (first?.spending ?? 0) - (first?.toSavings ?? 0)))
            Text("ריבית בפיקדונות מחושבת לפי התנאים שהזנת, פיקדון שמגיע לפירעון חוזר לעו״ש (אחרי מס), ותנועות מתוכננות נכנסות בחודש שלהן. כדי שהוצאה קבועה (למשל ״חיסכון״) תיכנס לחשבון חיסכון במקום להיעלם — בחר לה חשבון יעד בעריכת ההוצאה.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Table

    @Environment(\.isCompactWidth) private var compact

    private var tableCard: some View {
        Card {
            Text("פירוט לפי חודש")
                .font(.headline)
            if compact { compactTable } else { wideTable }
        }
    }

    /// iPhone: one block per month — the month and total on top, checking and savings under it, then the events.
    private var compactTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(months) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: m.index == 0 ? "היום" : m.label)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(verbatim: Fmt.moneyRounded(m.liquid))
                            .monospacedDigit()
                            .bold()
                    }
                    HStack(spacing: 4) {
                        Text("עו״ש")
                        Text(verbatim: Fmt.moneyRounded(m.checking))
                            .monospacedDigit()
                            .foregroundStyle(m.checking < 0 ? Color.red : Color.secondary)
                        Text(verbatim: "·")
                        Text("חיסכון")
                        Text(verbatim: Fmt.moneyRounded(m.savings)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !m.events.isEmpty {
                        Text(verbatim: m.events.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
                if m.id != months.last?.id { Divider() }
            }
        }
    }

    private var wideTable: some View {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("חודש")
                    Text("עו״ש")
                    Text("חיסכון")
                    Text("סה״כ")
                    Text("אירועים")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(months) { m in
                    GridRow {
                        Text(verbatim: m.index == 0 ? "היום" : m.label)
                        Text(verbatim: Fmt.moneyRounded(m.checking))
                            .monospacedDigit()
                            .foregroundStyle(m.checking < 0 ? Color.red : Color.primary)
                        Text(verbatim: Fmt.moneyRounded(m.savings)).monospacedDigit()
                        Text(verbatim: Fmt.moneyRounded(m.liquid)).monospacedDigit().bold()
                        Text(verbatim: m.events.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
    }
}

import SwiftUI

struct TrendsView: View {
    @EnvironmentObject private var store: Store
    @State private var openTrend: Trend?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: "מגמות", subtitle: "כמה באמת הולך על דברים שאין להם קטגוריה — דייטים, מתנות, יציאות") {
                    Button {
                        creating = true
                    } label: {
                        Label("מגמה חדשה", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Divider()
                if store.money.trends.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                            ForEach(store.money.trends) { trend in
                                Button {
                                    openTrend = trend
                                } label: {
                                    TrendCard(trend: trend, stats: store.money.stats(of: trend))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.deleteTrend(trend.id)
                                    } label: {
                                        Label("מחיקת המגמה", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                }
            }
            .navigationTitle("מגמות")
            .sheet(item: $openTrend) { trend in
                TrendDetailView(trendID: trend.id)
                    .environmentObject(store)
            }
            .sheet(isPresented: $creating) {
                NewTrendSheet { trend in
                    store.upsertTrend(trend)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openTrend = trend }
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("אין עדיין מגמות", systemImage: "tag")
        } description: {
            Text("מגמה מרכזת הוצאות שמפוזרות בין בתי עסק וקטגוריות. למשל ״דייטים״: מסעדה, קולנוע, פרחים ומונית.\nאחרי שיוצרים מגמה משייכים אליה חיובים מעמוד ״כרטיס אשראי״ (בתפריט ״צמד ל…״), תנועות, או הוצאות במזומן — ורואים כמה זה יוצא בחודש.\nמגמות הן לניתוח בלבד — הן לא משנות את התקציב ולא נספרות פעמיים.")
        } actions: {
            Button("מגמה חדשה") { creating = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Card

struct TrendCard: View {
    let trend: Trend
    let stats: TrendStats

    var body: some View {
        Card {
            HStack(alignment: .top) {
                Text(verbatim: trend.emoji)
                    .font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: trend.name)
                        .font(.headline)
                    Text(verbatim: "\(stats.count) פריטים")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("החודש")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: Fmt.money(stats.thisMonth))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(trend.monthlyLimit > 0 && stats.thisMonth > trend.monthlyLimit ? Color.red : Color.primary)
                }
            }
            if trend.monthlyLimit > 0 {
                ProgressView(value: min(stats.thisMonth, trend.monthlyLimit), total: trend.monthlyLimit) {
                    Text(verbatim: "תקרה: " + Fmt.money(trend.monthlyLimit))
                        .font(.caption)
                }
                .tint(stats.thisMonth > trend.monthlyLimit ? .red : .green)
            }
            TrendBars(months: stats.months, limit: trend.monthlyLimit)
            HStack {
                mini("חודש שעבר", stats.lastMonth)
                mini("ממוצע לחודש", stats.monthlyAverage)
                mini("סה״כ", stats.total)
            }
        }
        .contentShape(Rectangle())
    }

    private func mini(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: Fmt.money(value))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Monthly bars, oldest → newest (right → left in Hebrew).
struct TrendBars: View {
    let months: [TrendMonth]
    var limit: Double = 0
    var height: CGFloat = 70

    var body: some View {
        let top = max(months.map { $0.amount }.max() ?? 0, limit, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(months) { m in
                VStack(spacing: 4) {
                    Text(verbatim: m.amount == 0 ? " " : Fmt.compact(m.amount))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(limit > 0 && m.amount > limit ? Color.red : Color.accentColor)
                        .opacity(m.amount == 0 ? 0.2 : 1)
                        .frame(height: max(3, height * max(m.amount, 0) / top))
                    Text(verbatim: "\(m.key % 100)/\(m.key / 100 % 100)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + 36)
    }
}

// MARK: - New trend

struct NewTrendSheet: View {
    let onCreate: (Trend) -> Void
    @State private var trend = Trend()

    private let suggestions: [(String, String)] = [
        ("💕", "דייטים"), ("🎁", "מתנות"), ("🍔", "אוכל בחוץ"), ("🎉", "יציאות עם חברים"),
        ("🚕", "מוניות"), ("☕️", "קפה"), ("🎮", "תחביבים"), ("✈️", "חופשות")
    ]

    var body: some View {
        SheetContainer(title: "מגמה חדשה", saveTitle: "יצירה", minHeight: 380, onSave: {
            var t = trend
            t.name = t.name.trimmingCharacters(in: .whitespaces)
            if t.name.isEmpty { t.name = "מגמה חדשה" }
            if t.emoji.isEmpty { t.emoji = "🏷️" }
            onCreate(t)
        }) {
            Section {
                FormTextField("שם", text: $trend.name, prompt: Text("למשל: דייטים"))
                FormTextField("אימוג׳י", text: $trend.emoji)
                AmountField(title: "תקרה חודשית (לא חובה)", value: $trend.monthlyLimit)
            } footer: {
                Text("אחרי היצירה משייכים חיובים מעמוד ״כרטיס אשראי״ או מתוך המגמה עצמה.")
            }
            Section("הצעות") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(suggestions, id: \.1) { s in
                        Button(s.0 + " " + s.1) {
                            trend.emoji = s.0
                            trend.name = s.1
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Detail

struct TrendDetailView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let trendID: UUID

    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var entryDate = Date()
    @State private var entryAmount: Double = 0
    @State private var entryNote = ""
    @State private var entryKey = UUID()

    private var trend: Trend { store.money.trends.first { $0.id == trendID } ?? Trend() }

    private func binding<T>(_ path: WritableKeyPath<Trend, T>) -> Binding<T> {
        Binding(
            get: { trend[keyPath: path] },
            set: { value in
                guard let i = store.money.trends.firstIndex(where: { $0.id == trendID }) else { return }
                store.money.trends[i][keyPath: path] = value
            }
        )
    }

    var body: some View {
        let stats = store.money.stats(of: trend)
        let items = store.money.items(of: trend)
        SheetContainer(title: trend.emoji + " " + trend.name, width: 720, minHeight: 700, onSave: nil) {
            Section {
                TrendBars(months: stats.months, limit: trend.monthlyLimit, height: 90)
                RateLine(title: "החודש", value: Fmt.money(stats.thisMonth))
                RateLine(title: "חודש שעבר", value: Fmt.money(stats.lastMonth))
                RateLine(title: "ממוצע לחודש", value: Fmt.money(stats.monthlyAverage))
                RateLine(title: "סה״כ (\(stats.count) פריטים)", value: Fmt.money(stats.total))
            } header: {
                Text("לפי חודש")
            } footer: {
                Text("החודש נקבע לפי תאריך הקנייה. מגמות הן לניתוח בלבד — הן לא משנות את התקציב והסיכום.")
            }

            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("הוספת חיובי אשראי ותנועות…", systemImage: "plus.circle")
                }
                HStack {
                    DatePicker("", selection: $entryDate, displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    TextField("", text: $entryNote, prompt: Text("תיאור (למשל: מזומן במסעדה)"))
                        .labelsHidden()
                    AmountField(title: "", value: $entryAmount)
                        .id(entryKey)
                        .regularWidth(190, compact: 110)
                    Button("הוסף") {
                        store.addEntry(TrendEntry(date: entryDate, amount: entryAmount, note: entryNote), to: trendID)
                        entryAmount = 0
                        entryNote = ""
                        entryKey = UUID()
                    }
                    .disabled(entryAmount == 0)
                }
            } header: {
                Text("הוספה")
            } footer: {
                Text("הוצאה ידנית — למשל מזומן, ביט, או מישהו אחר ששילם ואתה החזרת. היא נרשמת רק במגמה, לא בעו״ש.")
            }

            Section {
                if items.isEmpty {
                    Text("עוד אין פריטים במגמה.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    TrendItemRow(item: item, trendID: trendID)
                }
            } header: {
                Text(verbatim: "פריטים (\(items.count))")
            }

            Section {
                FormTextField("שם", text: binding(\.name))
                FormTextField("אימוג׳י", text: binding(\.emoji))
                AmountField(title: "תקרה חודשית (0 = בלי)", value: binding(\.monthlyLimit))
                Button("מחיקת המגמה…", role: .destructive) { confirmDelete = true }
            } header: {
                Text("הגדרות")
            }
        }
        .sheet(isPresented: $showPicker) {
            TrendPickerSheet(trendID: trendID)
                .environmentObject(store)
        }
        .confirmationDialog("למחוק את המגמה?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחק", role: .destructive) {
                store.deleteTrend(trendID)
                dismiss()
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("החיובים עצמם לא נמחקים — רק השיוך שלהם למגמה.")
        }
    }
}

struct TrendItemRow: View {
    @EnvironmentObject private var store: Store
    let item: TrendItem
    let trendID: UUID
    @State private var editingShare = false
    @State private var shareText = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                Text(verbatim: Fmt.date(item.date) + " · " + item.detail
                     + (item.fullAmount.map { " · מתוך " + Fmt.money($0) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if editingShare, case .card(let id) = item.source {
                TextField("", text: $shareText, prompt: Text(verbatim: "סכום"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { commit(id) }
                Button("שמור") { commit(id) }
            } else {
                Text(verbatim: Fmt.money(item.amount))
                    .monospacedDigit()
            }
            Menu {
                if case .card = item.source {
                    Button("רק חלק מהחיוב שייך למגמה…") {
                        shareText = AmountField.display(item.amount)
                        editingShare = true
                    }
                    if item.fullAmount != nil, case .card(let id) = item.source {
                        Button("החזר לסכום המלא") { store.setShare(nil, card: id, in: trendID) }
                    }
                }
                Button("הסר מהמגמה", role: .destructive) {
                    store.removeItem(item, from: trendID)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func commit(_ id: String) {
        let value = AmountField.parse(shareText)
        store.setShare(value > 0 ? value : nil, card: id, in: trendID)
        editingShare = false
    }
}

// MARK: - Picker

struct TrendPickerSheet: View {
    @EnvironmentObject private var store: Store
    let trendID: UUID
    @State private var search = ""
    @State private var onlyUnassigned = false

    private var trend: Trend { store.money.trends.first { $0.id == trendID } ?? Trend() }

    private var cards: [CardTransaction] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.money.cardTransactions
            .filter { q.isEmpty || $0.merchant.lowercased().contains(q) || $0.category.lowercased().contains(q) }
            .filter { !onlyUnassigned || store.money.trends(containing: $0.id).isEmpty }
            .sorted { $0.date > $1.date }
    }

    private var transactions: [MoneyTransaction] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.money.transactions
            .filter { $0.kind == .expense && $0.salaryKey == nil }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        SheetContainer(title: "הוספה ל" + trend.name, width: 640, minHeight: 620, onSave: nil) {
            Section {
                TextField("", text: $search, prompt: Text("חיפוש לפי בית עסק או קטגוריה"))
                    .labelsHidden()
                Toggle("רק חיובים שלא שויכו לאף מגמה", isOn: $onlyUnassigned)
            }
            Section("חיובי אשראי") {
                if cards.isEmpty {
                    Text("אין חיובים. מייבאים אותם בעמוד ״כרטיס אשראי״.")
                        .foregroundStyle(.secondary)
                }
                ForEach(cards) { tx in
                    Toggle(isOn: Binding(
                        get: { trend.cardIDs.contains(tx.id) },
                        set: { _ in store.toggleCard(tx.id, in: trendID) }
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: tx.merchant)
                                Text(verbatim: Fmt.date(tx.date) + (tx.category.isEmpty ? "" : " · " + tx.category))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(verbatim: Fmt.money(tx.amount))
                                .monospacedDigit()
                        }
                    }
                    .checkboxToggle()
                }
            }
            if !transactions.isEmpty {
                Section("תנועות (הוצאות)") {
                    ForEach(transactions) { t in
                        Toggle(isOn: Binding(
                            get: { trend.transactionIDs.contains(t.id) },
                            set: { _ in store.toggleTransaction(t.id, in: trendID) }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: t.title)
                                    Text(verbatim: Fmt.date(t.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(verbatim: Fmt.money(t.amount))
                                    .monospacedDigit()
                            }
                        }
                        .checkboxToggle()
                    }
                }
            }
        }
    }
}

import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct CardView: View {
    @EnvironmentObject private var store: Store

    @State private var selectedKey: Int?
    @State private var filter: Filter = .all
    @State private var message: String?
    @State private var isError = false
    @State private var dropTargeted = false
    @State private var importing = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, open, linked, ignored
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "הכל"
            case .open: return "לא מצומד"
            case .linked: return "מצומד"
            case .ignored: return "מוסתר"
            }
        }
    }

    static func billingTitle(_ key: Int) -> String {
        Fmt.monthTitle(year: key / 100, month: key % 100)
    }

    private var keys: [Int] { store.money.cardBillingKeys }

    private var key: Int? {
        if let selectedKey, keys.contains(selectedKey) { return selectedKey }
        return store.money.cardStatementKeys.first ?? keys.first
    }

    private var monthTxs: [CardTransaction] {
        guard let key else { return [] }
        return store.money.cardTransactions(billingKey: key)
    }

    private var shown: [CardTransaction] {
        switch filter {
        case .all: return monthTxs
        case .open: return monthTxs.filter { $0.isVariable }
        case .linked: return monthTxs.filter { !$0.ignored && ($0.linkedExpenseID != nil || $0.linkedTrackedID != nil) }
        case .ignored: return monthTxs.filter { $0.ignored }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: SidebarItem.card.title, subtitle: subtitle, guide: .card) {
                    if keys.count > 1 {
                        Picker("חודש חיוב", selection: Binding(get: { key ?? 0 }, set: { selectedKey = $0 })) {
                            ForEach(keys, id: \.self) { k in
                                Text(verbatim: "חיוב " + CardView.billingTitle(k)).tag(k)
                            }
                        }
                        .fixedSize()
                    }
                    Button(action: importFile) {
                        Label("ייבוא קובץ (Max / CAL)…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Divider()
                if store.money.cardTransactions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            banners
                            tiles
                            AdaptiveStack {
                                categoriesCard
                                fixedCard
                            }
                            if !store.money.installmentPlans.isEmpty {
                                installmentsCard
                            }
                            CardDaysCard()
                            transactionsCard
                        }
                        .padding(20)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                }
            }
            .navigationTitle(SidebarItem.card.title)
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { for url in urls { runImport(url) } }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "xlsx" }) else { return false }
                runImport(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var subtitle: String {
        guard let last = store.money.cardImports.first else { return "ייבוא פירוט עסקאות מ-Max או מ-CAL, וצימוד להוצאות הקבועות" }
        return "ייבוא אחרון: " + Fmt.date(last.importedAt) + " · " + last.fileName
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.and.123")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text("עוד לא יובא פירוט אשראי")
                .font(.title2.weight(.semibold))
            howTo
                .frame(maxWidth: 520)
            Button(action: importFile) {
                Label("ייבוא קובץ (Max / CAL)…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("אפשר גם לגרור את הקובץ לחלון הזה.")
                .foregroundStyle(.secondary)
            messageView
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("איך מייצאים מ-Max:").font(.headline)
            Text("1. נכנסים לאתר max.co.il ← ״פירוט עסקאות וחיובים״.")
            Text("2. בוחרים את חודש החיוב (״כל הכרטיסים״).")
            Text("3. לוחצים על אייקון האקסל (״ייצוא לאקסל״) ושומרים.")
            Text("4. מייבאים כאן. הכי טוב — ביום שהחיוב יורד מהבנק (אצלך בדרך כלל ב-\(store.money.usualChargeDay ?? 2) לחודש).")
            Text("איך מייצאים מ-CAL (כאל):").font(.headline).padding(.top, 6)
            Text("1. נכנסים לאתר או לאפליקציה של כאל ← ״פירוט עסקאות״.")
            Text("2. בוחרים את התקופה ולוחצים על ״ייצוא לאקסל״.")
            Text("3. מייבאים כאן את הקובץ (״פירוט עסקאות וזיכויים.xlsx״). כאל לא מסווגת קטגוריות, אז החיובים יופיעו בלי קטגוריה.")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageView: some View {
        if let message {
            Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
                .font(.callout)
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if message != nil {
            Card { messageView }
        }
        if store.cardImportDue {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "החיוב של " + Fmt.monthNames[Calendar.current.component(.month, from: Date()) - 1] + " כבר ירד מהבנק — זה הזמן לייבא את הפירוט שלו")
                            .font(.headline)
                        Text("אחרי הייבוא תוכל לצמד כל חיוב להוצאה הקבועה שלו. בתי עסק שכבר צימדת בעבר יצומדו לבד.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("ייבוא…", action: importFile)
                }
            }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let s = CardMonthSummary.of(monthTxs)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "סה״כ חיוב" + (key.map { " — " + CardView.billingTitle($0) } ?? ""), value: Fmt.money(rounded(s.total)), icon: "creditcard.fill")
            StatTile(title: "מצומד להוצאות קבועות", value: Fmt.money(rounded(s.fixedLinked)), icon: "link")
            if s.trackedLinked != 0 {
                StatTile(title: "רכישות במעקב", value: Fmt.money(rounded(s.trackedLinked)), icon: "bag.fill")
            }
            StatTile(title: "הוצאות משתנות", value: Fmt.money(rounded(s.variable)), icon: "cart.fill")
            if s.installments != 0 {
                StatTile(title: "מתוכן תשלומים", value: Fmt.money(rounded(s.installments)), icon: "calendar.badge.clock")
            }
            if s.owed > 0 {
                StatTile(title: "שילמתי בשביל אחרים", value: Fmt.money(rounded(s.owed)), icon: "arrow.uturn.backward.circle")
            }
            if s.pending != 0 {
                StatTile(title: "ממתין לקליטה (כלול)", value: Fmt.money(rounded(s.pending)), icon: "hourglass")
            }
        }
    }

    private func rounded(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    // MARK: Categories

    private var categoriesCard: some View {
        let s = CardMonthSummary.of(monthTxs)
        let items = s.byCategory.filter { $0.amount > 0 }
        return Card {
            Text("הוצאות משתנות לפי קטגוריה")
                .font(.headline)
            if items.isEmpty {
                Text("אין הוצאות משתנות בחודש הזה — הכל מצומד.")
                    .foregroundStyle(.secondary)
            } else {
                let top = max(items.first?.amount ?? 1, 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: item.name)
                                Spacer()
                                Text(verbatim: Fmt.money(rounded(item.amount)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color.teal.gradient)
                                    .frame(width: max(4, geo.size.width * item.amount / top))
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }
            let avg = store.money.averageCardVariable()
            if avg > 0 {
                Divider()
                RateLine(title: "ממוצע הוצאות משתנות בחודש (עד 3 חיובים אחרונים)", value: Fmt.moneyRounded(avg))
                Text("הממוצע נכנס לסיכום החודש ולתחזית בחודשים שעוד לא יובא להם פירוט.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fixed expenses vs card

    private var fixedCard: some View {
        let actuals = key.map { store.cardActuals(billingKey: $0) } ?? [:]
        let expenses = store.budget.expenses.filter { actuals[$0.id] != nil }
        return Card {
            Text("הוצאות קבועות — מתוכנן מול אשראי")
                .font(.headline)
            if expenses.isEmpty {
                Text("עוד לא צימדת חיובים להוצאות קבועות. בחר ״מה זה?״ ליד חיוב ברשימה למטה.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(expenses) { item in
                    let planned = item.amount(base: store.budget.expenseBase)
                    let actual = actuals[item.id] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name).font(.body.weight(.medium))
                            Spacer()
                            // A refund bigger than the charges leaves a credit, not a negative spend.
                            Text(verbatim: actual < 0
                                 ? "זיכוי " + Fmt.money(rounded(-actual)) + " / " + Fmt.moneyRounded(planned)
                                 : Fmt.money(rounded(actual)) + " / " + Fmt.moneyRounded(planned))
                                .monospacedDigit()
                                .foregroundStyle(actual > planned + 0.5 ? Color.red : actual < 0 ? Color.green : Color.primary)
                        }
                        // A value outside 0...total turns the bar into an endless "loading" animation.
                        ProgressView(value: min(max(actual, 0), max(planned, 0.01)), total: max(planned, 0.01))
                            .tint(actual > planned + 0.5 ? .red : .green)
                    }
                }
                Text("הוצאה קבועה כבר נספרת בתקציב, ולכן חיוב שמצומד אליה לא נספר שוב בהוצאות המשתנות.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Installments

    private var installmentsCard: some View {
        let plans = store.money.installmentPlans
        let active = plans.filter { $0.isActive }
        let done = plans.filter { !$0.isActive }
        return Card {
            HStack {
                Text("תשלומים")
                    .font(.headline)
                Spacer()
                let future = active.reduce(0) { sum, p in sum + p.payments.filter { $0.chargeDate > Date() }.reduce(0) { $0 + $1.amount } }
                if future > 0 {
                    Text(verbatim: "עוד יחויב: " + Fmt.money(rounded(future)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("קנייה גדולה בתשלומים נספרת רק לפי מה שיורד בכל חודש. תשלומים שעוד לא הופיעו בקובץ נכנסים לסיכום ולתחזית לפי הצפי.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(active + done.prefix(3)) { plan in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: plan.merchant)
                            .font(.body.weight(.medium))
                        if !plan.countsAsVariable {
                            Text("מצומד")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                        Spacer()
                        Text(verbatim: Fmt.money(plan.total) + " ב-\(plan.count) תשלומים")
                            .monospacedDigit()
                    }
                    Text(verbatim: "נקנה " + Fmt.date(plan.purchaseDate)
                         + (plan.next.map { " · תשלום הבא " + Fmt.date($0.chargeDate) + " — " + Fmt.money($0.amount) } ?? " · הסתיים"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(plan.payments) { p in
                            let past = p.chargeDate <= Date()
                            VStack(spacing: 2) {
                                Text(verbatim: "\(p.number)/\(plan.count)")
                                    .font(.caption2.weight(.semibold))
                                Text(verbatim: Fmt.money(p.amount))
                                    .font(.caption2)
                                    .monospacedDigit()
                                Text(verbatim: "\(Calendar.current.component(.day, from: p.chargeDate)).\(Calendar.current.component(.month, from: p.chargeDate))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(6)
                            .frame(minWidth: 64)
                            .background(past ? Color.green.opacity(0.18) : (p.imported ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(p.imported ? Color.clear : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            )
                            .help(past ? "חויב" : (p.imported ? "בקובץ — יחויב" : "צפוי — עוד לא בקובץ"))
                        }
                    }
                }
                if plan.id != (active + done.prefix(3)).last?.id { Divider() }
            }
            Text("ירוק = כבר ירד · כחול = מופיע בקובץ ויחויב · מקווקו = צפוי")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Transactions

    @Environment(\.isCompactWidth) private var compact

    private var filterPicker: some View {
        Picker("סינון", selection: $filter) {
            ForEach(Filter.allCases) { f in Text(f.title).tag(f) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var transactionsCard: some View {
        Card {
            if compact {
                Text("חיובים")
                    .font(.headline)
                filterPicker
            } else {
                HStack {
                    Text("חיובים")
                        .font(.headline)
                    Spacer()
                    filterPicker.fixedSize()
                }
            }
            if shown.isEmpty {
                Text("אין חיובים להצגה.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { tx in
                CardTxRow(tx: tx)
                if tx.id != shown.last?.id { Divider() }
            }
        }
    }

    // MARK: Import

    #if os(iOS)
    private func importFile() { importing = true }
    #else
    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let xlsx = UTType(filenameExtension: "xlsx") { panel.allowedContentTypes = [xlsx] }
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.prompt = "ייבוא"
        if panel.runModal() == .OK {
            for url in panel.urls { runImport(url) }
        }
    }
    #endif

    private func runImport(_ url: URL) {
        do {
            let record = try store.importCardFile(url)
            isError = false
            message = record.summary
            if let first = store.money.cardStatementKeys.first { selectedKey = first }
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

// MARK: - Row

struct CardTxRow: View {
    @EnvironmentObject private var store: Store
    let tx: CardTransaction
    @State private var newTrend = false
    @State private var owedSheet = false
    @State private var classifying = false
    @Environment(\.isCompactWidth) private var compact

    private var linkedName: (String, String)? {
        if let id = tx.linkedExpenseID, let e = store.budget.expenses.first(where: { $0.id == id }) {
            return (e.name, "link")
        }
        if let id = tx.linkedTrackedID, let t = store.budget.trackedItems.first(where: { $0.id == id }) {
            return (t.emoji + " " + t.name, "bag")
        }
        return nil
    }

    private var details: String {
        var parts: [String] = [tx.date.formatted(.dateTime.day().month(.abbreviated).locale(Fmt.locale))]
        if !tx.category.isEmpty { parts.append(tx.category) }
        if !tx.cardLast4.isEmpty { parts.append("כרטיס " + tx.cardLast4) }
        if !tx.note.isEmpty { parts.append(tx.note) }
        if tx.status != .charged { parts.append(tx.status.title) }
        if tx.occurrence > 1 {
            parts.append("רכישה זהה מס׳ \(tx.occurrence) באותו יום")
        } else if store.money.cardTransactions.contains(where: { $0.id == tx.baseID + "#2" }) {
            parts.append("נקנה יותר מפעם אחת באותו יום")
        }
        if tx.originalCurrency != "₪" && !tx.originalCurrency.isEmpty {
            parts.append(Fmt.number(tx.originalAmount) + " " + tx.originalCurrency)
        } else if abs(tx.originalAmount - tx.amount) > 0.01 && tx.originalAmount != 0 {
            parts.append("עסקה מקורית " + Fmt.money(tx.originalAmount))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if compact { compactBody } else { wideBody }
        }
        .padding(.vertical, 4)
        .opacity(tx.ignored ? 0.5 : 1)
        .sheet(isPresented: $owedSheet) {
            OwedQuickSheet(tx: tx).environmentObject(store)
        }
        .sheet(isPresented: $classifying) {
            ClassifyCardSheet(txID: tx.id,
                              onOwed: { after { owedSheet = true } },
                              onNewTrend: { after { newTrend = true } })
                .environmentObject(store)
        }
        .sheet(isPresented: $newTrend) {
            NewTrendSheet { trend in
                var trend = trend
                trend.cardIDs = [tx.id]
                store.upsertTrend(trend)
            }
        }
    }

    /// Opens a second sheet once the first one has closed.
    private func after(_ open: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: open)
    }

    private var amountText: some View {
        Text(verbatim: Fmt.money((tx.amount * 100).rounded() / 100))
            .monospacedDigit()
            .foregroundStyle(tx.amount < 0 ? Color.green : (tx.ignored ? Color.secondary : Color.primary))
    }

    private var hasTags: Bool {
        tx.owedPortion > 0 || store.money.maaser.isMaaser(tx) || linkedName != nil
            || !store.money.trends(containing: tx.id).isEmpty
    }

    /// iPhone: name and amount on top, details under them, then the tags and the link button.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tx.merchant)
                    .font(.body.weight(.medium))
                    .strikethrough(tx.ignored)
                    .lineLimit(2)
                Spacer(minLength: 8)
                amountText
                    .font(.body.weight(.semibold))
                    .fixedSize()
            }
            Text(verbatim: details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if hasTags {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { tags }
                    }
                } else {
                    Spacer()
                }
                linkMenu
            }
        }
    }

    private var wideBody: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.merchant)
                    .font(.body.weight(.medium))
                    .strikethrough(tx.ignored)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            tags
            amountText
                .frame(minWidth: 90, alignment: .trailing)
            linkMenu
        }
    }

    @ViewBuilder private var tags: some View {
            if tx.owedPortion > 0 {
                Text(verbatim: "↩︎ יחזירו " + Fmt.money(tx.owedPortion))
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
            if store.money.maaser.isMaaser(tx) {
                Text("🤲 מעשרות")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
            ForEach(store.money.trends(containing: tx.id)) { t in
                Text(verbatim: t.emoji + " " + t.name)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
            if let linkedName {
                Label(linkedName.0, systemImage: linkedName.1)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
    }

    private var linkMenu: some View {
        Button {
            classifying = true
        } label: {
            Label(hasTags || tx.ignored ? "שנה" : "מה זה?", systemImage: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

// MARK: - Cards and their charge days

/// Each card: its name, the day the bank takes it and how many days later it leaves the checking; and cards whose
/// statements aren't imported (e.g. the bank's own card), with what they usually charge.
struct CardDaysCard: View {
    @EnvironmentObject private var store: Store

    private var rows: [CardSetting] {
        let money = store.money
        let imported = money.importedCards.map { money.setting(card: $0) ?? CardSetting(last4: $0) }
        let manual = money.cardSettings.filter { $0.last4.isEmpty }
        return imported + manual
    }

    var body: some View {
        Card {
            Text("כרטיסים וימי חיוב")
                .font(.headline)
            Text("כדי שדף העו״ש יוריד כל כרטיס ביום שהבנק באמת מוריד אותו. כרטיס שלא מייבאים לו קובץ (למשל כרטיס של הבנק) — מוסיפים עם סכום משוער לחודש.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { setting in
                CardDayRow(setting: setting, usualDay: store.money.usualChargeDay)
                Divider()
            }
            Button {
                store.upsertCardSetting(CardSetting(name: "כרטיס הבנק", chargeDay: store.money.usualChargeDay ?? 2,
                                                    monthlyEstimate: 500))
            } label: {
                Label("הוסף כרטיס בלי קובץ", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct CardDayRow: View {
    @EnvironmentObject private var store: Store
    let setting: CardSetting
    let usualDay: Int?

    private func update(_ change: (inout CardSetting) -> Void) {
        var s = setting
        change(&s)
        store.upsertCardSetting(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("שם", text: Binding(get: { setting.name }, set: { v in update { $0.name = v } }),
                          prompt: Text(setting.last4.isEmpty ? "שם הכרטיס" : "כרטיס " + setting.last4))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                if !setting.last4.isEmpty {
                    Text(verbatim: "•••• " + setting.last4)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if setting.last4.isEmpty {
                    Button(role: .destructive) {
                        store.deleteCardSetting(setting)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Stepper(value: Binding(get: { setting.chargeDay ?? 0 },
                                   set: { v in update { $0.chargeDay = v == 0 ? nil : v } }), in: 0...31) {
                Text(setting.chargeDay.map { "יום החיוב בבנק: ב-\($0) לחודש" }
                     ?? (setting.last4.isEmpty ? "יום החיוב בבנק: ביום המשכורת" : "יום החיוב בבנק: כמו בקובץ" + (usualDay.map { " (בדרך כלל ב-\($0))" } ?? "")))
            }
            Stepper(value: Binding(get: { setting.delayDays }, set: { v in update { $0.delayDays = v } }), in: 0...7) {
                Text(setting.delayDays == 0 ? "יורד מהעו״ש באותו יום" : "יורד מהעו״ש \(setting.delayDays == 1 ? "יום" : "\(setting.delayDays) ימים") אחרי")
            }
            if setting.last4.isEmpty {
                AmountField(title: "בדרך כלל בחודש", value: Binding(get: { setting.monthlyEstimate },
                                                                     set: { v in update { $0.monthlyEstimate = v } }))
            }
        }
        .font(.callout)
    }
}

// MARK: - "מה זה?"

/// One place to say what a card charge is: how it counts in the budget (one choice), which trends it belongs to,
/// whether someone owes you for it, and maaser.
struct ClassifyCardSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let txID: String
    let onOwed: () -> Void
    let onNewTrend: () -> Void

    private var tx: CardTransaction? { store.money.cardTransactions.first { $0.id == txID } }

    private enum Kind: Hashable { case regular, fixed(UUID), tracked(UUID), ignored }

    private func kind(_ tx: CardTransaction) -> Kind {
        if tx.ignored { return .ignored }
        if let id = tx.linkedExpenseID { return .fixed(id) }
        if let id = tx.linkedTrackedID { return .tracked(id) }
        return .regular
    }

    private func set(_ kind: Kind, _ tx: CardTransaction) {
        if tx.ignored, kind != .ignored { store.setCardIgnored(tx.id, false) }
        switch kind {
        case .regular:
            if tx.linkedExpenseID != nil { store.linkCard(tx.id, toExpense: nil) }
            if tx.linkedTrackedID != nil { store.linkCard(tx.id, toTracked: nil) }
        case .fixed(let id): store.linkCard(tx.id, toExpense: id)
        case .tracked(let id): store.linkCard(tx.id, toTracked: id)
        case .ignored: store.setCardIgnored(tx.id, true)
        }
    }

    var body: some View {
        SheetContainer(title: "מה זה?", width: 480, onSave: nil) {
            if let tx {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx.merchant).font(.headline)
                            Text(verbatim: Fmt.date(tx.date) + (tx.category.isEmpty ? "" : " · " + tx.category))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: Fmt.money(tx.amount)).monospacedDigit().font(.headline)
                    }
                }
                Section {
                    choice("קנייה רגילה", detail: "נספרת בהוצאות המשתנות של החודש", selected: kind(tx) == .regular) {
                        set(.regular, tx)
                    }
                    ForEach(store.budget.expenses) { e in
                        choice("חלק מ״" + e.name + "״", detail: "הוצאה קבועה — כבר בתקציב, לא תיספר שוב. גם החיובים הבאים מבית העסק הזה",
                               selected: kind(tx) == .fixed(e.id)) { set(.fixed(e.id), tx) }
                    }
                    ForEach(store.budget.trackedItems) { t in
                        choice(t.emoji + " " + t.name, detail: "רכישה במעקב רכישות", selected: kind(tx) == .tracked(t.id)) {
                            set(.tracked(t.id), tx)
                        }
                    }
                    choice("לא לספור", detail: "כפול, או שכבר נרשם במקום אחר", selected: kind(tx) == .ignored) { set(.ignored, tx) }
                } header: {
                    Text("איך זה נספר בתקציב")
                }
                Section {
                    ForEach(store.money.trends) { t in
                        Toggle(t.emoji + " " + t.name, isOn: Binding(
                            get: { t.cardIDs.contains(tx.id) },
                            set: { _ in store.toggleCard(tx.id, in: t.id) }))
                    }
                    Button("מגמה חדשה…") { dismiss(); onNewTrend() }
                } header: {
                    Text("מגמות — לניתוח בלבד, לא משנה את התקציב")
                }
                Section("חייבים לי") {
                    if tx.owedPortion > 0 {
                        Text(verbatim: "מישהו צריך להחזיר " + Fmt.money(tx.owedPortion))
                        Button("ביטול — לא צריך להחזיר", role: .destructive) { store.removeCardFromReceivables(tx.id) }
                    } else if tx.amount > 0 {
                        Button("מישהו צריך להחזיר לי חלק מזה…") { dismiss(); onOwed() }
                    }
                }
                if store.money.maaser.enabled {
                    Section("מעשרות") {
                        Toggle("החיוב הזה הוא מעשרות", isOn: Binding(
                            get: { store.money.maaser.isMaaser(tx) },
                            set: { store.setCardMaaser(tx, on: $0, merchant: false) }))
                        if !store.money.maaser.isMaaser(tx) {
                            Button("כל החיובים מבית העסק הזה הם מעשרות") { store.setCardMaaser(tx, on: true, merchant: true) }
                        }
                    }
                }
            }
        }
    }

    private func choice(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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
                PageBar(title: "כרטיס אשראי", subtitle: subtitle) {
                    if keys.count > 1 {
                        Picker("חודש חיוב", selection: Binding(get: { key ?? 0 }, set: { selectedKey = $0 })) {
                            ForEach(keys, id: \.self) { k in
                                Text(verbatim: "חיוב " + CardView.billingTitle(k)).tag(k)
                            }
                        }
                        .fixedSize()
                    }
                    Button(action: importFile) {
                        Label("ייבוא קובץ מ-Max…", systemImage: "square.and.arrow.down")
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
                            transactionsCard
                        }
                        .padding(20)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                }
            }
            .navigationTitle("כרטיס אשראי")
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
        guard let last = store.money.cardImports.first else { return "ייבוא פירוט עסקאות מ-Max וצימוד להוצאות הקבועות" }
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
                Label("ייבוא קובץ מ-Max…", systemImage: "square.and.arrow.down")
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
        let open = monthTxs.filter { $0.isVariable }.count
        if open > 0, filter != .open {
            HStack {
                Image(systemName: "link.badge.plus")
                Text(verbatim: "\(open) חיובים עוד לא מצומדים. חיוב שהוא בעצם הוצאה קבועה (חשמל, טלפון, מנוי) — צמד אותו כדי שלא ייספר פעמיים.")
                Spacer()
                Button("הצג אותם") { filter = .open }
            }
            .font(.callout)
            .padding(12)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
                Text("עוד לא צימדת חיובים להוצאות קבועות. בחר ״צמד ל…״ ליד חיוב ברשימה למטה.")
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
                            Text(verbatim: Fmt.money(rounded(actual)) + " / " + Fmt.moneyRounded(planned))
                                .monospacedDigit()
                                .foregroundStyle(actual > planned + 0.5 ? Color.red : Color.primary)
                        }
                        ProgressView(value: min(actual, max(planned, 0.01)), total: max(planned, 0.01))
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
        .sheet(isPresented: $newTrend) {
            NewTrendSheet { trend in
                var trend = trend
                trend.cardIDs = [tx.id]
                store.upsertTrend(trend)
            }
        }
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
        Menu {
            Section("הוצאה קבועה — כל החיובים מבית העסק הזה") {
                ForEach(store.budget.expenses) { e in
                    Button {
                        store.linkCard(tx.id, toExpense: e.id)
                    } label: {
                        if tx.linkedExpenseID == e.id {
                            Label(e.name, systemImage: "checkmark")
                        } else {
                            Text(e.name)
                        }
                    }
                }
                if store.budget.expenses.isEmpty {
                    Text("אין הוצאות קבועות")
                }
            }
            if !store.budget.trackedItems.isEmpty {
                Section("מעקב רכישות — נרשם כרכישה") {
                    ForEach(store.budget.trackedItems) { t in
                        Button {
                            store.linkCard(tx.id, toTracked: t.id)
                        } label: {
                            if tx.linkedTrackedID == t.id {
                                Label(t.emoji + " " + t.name, systemImage: "checkmark")
                            } else {
                                Text(t.emoji + " " + t.name)
                            }
                        }
                    }
                }
            }
            Section("חייבים לי") {
                if tx.owedPortion > 0 {
                    Button("ביטול — לא צריך להחזיר") { store.removeCardFromReceivables(tx.id) }
                } else if tx.amount > 0 {
                    Button("מישהו צריך להחזיר לי…") { owedSheet = true }
                }
            }
            if store.money.maaser.enabled {
                Section("מעשרות") {
                    if store.money.maaser.isMaaser(tx) {
                        Button("בטל סימון מעשרות") { store.setCardMaaser(tx, on: false, merchant: false) }
                    } else {
                        Button("החיוב הזה הוא מעשרות") { store.setCardMaaser(tx, on: true, merchant: false) }
                        Button("כל החיובים מבית העסק הזה הם מעשרות") { store.setCardMaaser(tx, on: true, merchant: true) }
                    }
                }
            }
            Section("מגמות — לניתוח, לא משנה את התקציב") {
                ForEach(store.money.trends) { t in
                    Button {
                        store.toggleCard(tx.id, in: t.id)
                    } label: {
                        if t.cardIDs.contains(tx.id) {
                            Label(t.emoji + " " + t.name, systemImage: "checkmark")
                        } else {
                            Text(t.emoji + " " + t.name)
                        }
                    }
                }
                Button("מגמה חדשה…") { newTrend = true }
            }
            Divider()
            if tx.linkedExpenseID != nil {
                Button("בטל צימוד (הוצאה משתנה)") { store.linkCard(tx.id, toExpense: nil) }
            }
            if tx.linkedTrackedID != nil {
                Button("בטל צימוד למעקב") { store.linkCard(tx.id, toTracked: nil) }
            }
            Button(tx.ignored ? "החזר לחישוב" : "הסתר מהחישוב (כבר נרשם / כפול)") {
                store.setCardIgnored(tx.id, !tx.ignored)
            }
        } label: {
            Label(tx.linkedExpenseID == nil && tx.linkedTrackedID == nil ? "צמד ל…" : "שנה", systemImage: "link")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

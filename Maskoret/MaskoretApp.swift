import SwiftUI
#if os(iOS)
import GoogleSignIn
#endif

@main
struct MaskoretApp: App {
    @StateObject private var store = Store()
    @StateObject private var insights = InsightsEngine()
    @StateObject private var account = UserAccount()
    @StateObject private var sync = ServerSync()
    @StateObject private var support = SupportCenter()
    @StateObject private var announcements = AnnouncementCenter()
    @StateObject private var whatsNew = WhatsNewCenter()
    #if os(macOS)
    @StateObject private var updater = Updater()
    #endif

    init() {
        #if os(macOS)
        // Before anything reads the keychain: take over the items the previous version handed over in an update.
        KeychainHandoff.importIfNeeded()
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup("מחשבון שכר") {
            ContentView()
                // Inside the environment objects below — they read them.
                .serverSyncLifecycle()
                .modifier(UpdatePrompt())
                .modifier(AppNews(announcements: announcements, whatsNew: whatsNew))
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(insights)
                .environmentObject(sync)
                .environmentObject(account)
                .environmentObject(support)
                .environmentObject(announcements)
                .hebrew()
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #else
        WindowGroup {
            PhoneRoot()
                // Inside the environment objects below — they read them.
                .serverSyncLifecycle()
                .modifier(AppNews(announcements: announcements, whatsNew: whatsNew))
                .environmentObject(store)
                .environmentObject(insights)
                .environmentObject(sync)
                .environmentObject(account)
                .environmentObject(support)
                .environmentObject(announcements)
                .hebrew()
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        #endif
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case summary, money, budget
    case incomes, deductions, expenses, card, accounts, transactions, forecast, history, maaser, owed, tracked, trends, insights, tax, account, support, admin, backup, updates

    /// The screens grouped under "הכסף שלי" and "תקציב", as tabs inside them.
    static let moneyTabs: [SidebarItem] = [.transactions, .card, .accounts]
    static let budgetTabs: [SidebarItem] = [.incomes, .deductions, .expenses, .tracked]

    /// The sidebar / tab item that shows this screen.
    var home: SidebarItem {
        if SidebarItem.moneyTabs.contains(self) { return .money }
        if SidebarItem.budgetTabs.contains(self) { return .budget }
        return self
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "בית"
        case .money: return "הכסף שלי"
        case .budget: return "תקציב"
        case .incomes: return "הכנסות"
        case .deductions: return "ניכויים"
        case .expenses: return "הוצאות קבועות"
        case .tracked: return "מעקב רכישות"
        case .trends: return "מגמות"
        case .maaser: return "מעשרות"
        case .owed: return "חייבים לי"
        case .insights: return "תובנות AI"
        case .card: return "אשראי"
        case .accounts: return "חיסכון"
        case .transactions: return "עו״ש"
        case .forecast: return "תחזית"
        case .history: return "חודשים"
        case .tax: return "נתוני מס"
        case .account: return "חשבון ומשק בית"
        case .support: return "תמיכה ודיווח תקלות"
        case .admin: return "ניהול משתמשים"
        case .backup: return "גרסאות קודמות"
        case .updates: return "עדכונים"
        }
    }

    var icon: String {
        switch self {
        case .summary: return "house.fill"
        case .money: return "creditcard.fill"
        case .budget: return "list.bullet.rectangle.fill"
        case .incomes: return "banknote.fill"
        case .deductions: return "building.columns.fill"
        case .expenses: return "cart.fill"
        case .tracked: return "bag.fill"
        case .trends: return "tag.fill"
        case .maaser: return "heart.circle"
        case .owed: return "arrow.uturn.backward.circle"
        case .insights: return "sparkles"
        case .card: return "creditcard"
        case .accounts: return "building.columns.circle"
        case .transactions: return "arrow.left.arrow.right"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .history: return "calendar"
        case .tax: return "slider.horizontal.3"
        case .account: return "person.crop.circle"
        case .support: return "bubble.left.and.text.bubble.right"
        case .admin: return "person.2.badge.gearshape"
        case .backup: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        }
    }
}

extension SidebarItem {
    /// One line at the top of the screen: what's here and what you do with it. Nil where the title says it all.
    var intro: String? {
        switch self {
        case .summary: return "התמונה של החודש: כמה נכנס, כמה כבר יצא, כמה צפוי להישאר ומה מחכה לטיפול."
        case .transactions: return "כמו דף הבנק: כל מה שנכנס ויוצא מהעו״ש, עם היתרה אחרי כל שורה. משכורת, הוצאות קבועות וחיובי אשראי נכנסים לבד."
        case .card: return "העסקאות בכרטיסי האשראי. כאן מייבאים את קובץ הפירוט מ-Max או מ-CAL ומשייכים עסקאות למגמות."
        case .accounts: return "כמה כסף יש לך עכשיו ואיפה: עו״ש, חסכונות, פיקדונות והשקעות."
        case .incomes: return "המשכורת וההכנסות הנוספות. מכאן מחושב הנטו הצפוי בכל חודש."
        case .deductions: return "מה שיורד מהמשכורת לפני שהיא מגיעה לבנק, מעבר למס ולביטוח הלאומי."
        case .expenses: return "הוצאות שחוזרות כל חודש, כמו שכירות, חשמל ומנויים. הן יורדות מהעו״ש לבד בתאריך שלהן."
        case .tracked: return "רכישות שחוזרות מדי פעם ולא כל חודש, כדי לדעת כמה הן עולות בממוצע."
        case .forecast: return "לאן הכסף שלך הולך בחודשים הקרובים, לפי ההכנסות וההוצאות."
        case .history: return "כל חודש שנשמר: הנטו שנכנס בפועל מול ההערכה. מכאן מתקנים או מוחקים חודש."
        case .maaser: return "כמה צריך לתת לפי מה שנכנס, כמה כבר נתת וכמה נשאר."
        case .owed: return "כסף שאחרים חייבים לך, ומה כבר הוחזר."
        case .trends: return "תגיות לדברים שאין להם קטגוריה, כמו דייטים, מתנות ויציאות, כדי לראות כמה באמת הולך עליהם."
        case .insights: return "שאלות ותובנות על הכסף שלך, בעזרת מודל AI."
        default: return nil
        }
    }

    /// Other words people use for what's on this screen, for the screen search.
    var keywords: [String] {
        switch self {
        case .summary: return ["סיכום", "ראשי", "נשאר", "עוגה", "לאן הולך הנטו", "שמור חודש", "תלוש", "תלוש שכר"]
        case .transactions: return ["תנועות", "בנק", "יתרה", "דף חשבון", "חשבון עובר ושב"]
        case .card: return ["כרטיס אשראי", "מקס", "Max", "כאל", "CAL", "ייבוא", "פירוט עסקאות", "חיוב"]
        case .accounts: return ["חסכונות", "חשבונות", "פיקדון", "השקעות", "קופת גמל", "קרן השתלמות"]
        case .incomes: return ["משכורת", "שכר", "ברוטו", "נטו", "הכנסה"]
        case .deductions: return ["ניכוי", "פנסיה", "קרן השתלמות", "קופת חולים"]
        case .expenses: return ["קבועות", "הוצאות", "שכירות", "חשמל", "מנויים", "הוראת קבע"]
        case .tracked: return ["רכישות", "דלק", "ביגוד", "קניות"]
        case .forecast: return ["עתיד", "חודשים הבאים", "צפי"]
        case .history: return ["היסטוריה", "חודשים קודמים", "מחיקת חודש", "תלוש"]
        case .maaser: return ["מעשר", "צדקה", "תרומות", "חומש"]
        case .owed: return ["חובות", "הלוואה", "החזר", "חייבים"]
        case .trends: return ["תגיות", "קטגוריות", "דייטים", "מתנות"]
        case .insights: return ["AI", "בינה מלאכותית", "שאלות", "Claude", "LM Studio"]
        case .tax: return ["מס", "מס הכנסה", "נקודות זיכוי", "ביטוח לאומי", "מדרגות"]
        case .account: return ["חשבון", "משק בית", "שיתוף", "התחברות", "Google", "סנכרון", "יציאה", "מחיקת חשבון"]
        case .support: return ["עזרה", "תקלה", "באג", "פנייה", "צור קשר"]
        case .admin: return ["מנויים", "משתמשים", "הודעות לכולם", "משימות פיתוח"]
        case .backup: return ["גיבוי", "שחזור", "גרסה קודמת"]
        case .updates: return ["עדכון", "גרסה", "הורדה", "מה חדש"]
        default: return []
        }
    }

    /// The screens a search can open, in the order of the sidebar.
    static func searchable(isAdmin: Bool) -> [SidebarItem] {
        var items: [SidebarItem] = [.summary] + moneyTabs + budgetTabs
            + [.forecast, .history, .maaser, .owed, .trends, .insights, .tax, .account, .support, .backup]
        if isAdmin { items.append(.admin) }
        #if os(macOS)
        items.append(.updates)
        #endif
        return items
    }

    /// Where the screen sits, for the search results ("הכסף שלי ← עו״ש").
    var path: String {
        home == self ? title : home.title + " ← " + title
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [title, home.title, intro ?? ""] + keywords
        return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension SidebarItem {
    /// The screen for this item (shared by the Mac sidebar and the iPhone tabs).
    @ViewBuilder var screen: some View {
        switch self {
        case .summary: SummaryView()
        case .money: GroupScreen(tabs: SidebarItem.moneyTabs, keyPath: \.moneyTab)
        case .budget: GroupScreen(tabs: SidebarItem.budgetTabs, keyPath: \.budgetTab)
        case .incomes: IncomesView()
        case .deductions: CostsView(section: .deductions)
        case .expenses: CostsView(section: .expenses)
        case .tracked: TrackedItemsView()
        case .trends: TrendsView()
        case .maaser: MaaserView()
        case .owed: ReceivablesView()
        case .insights: InsightsView()
        case .card: CardView()
        case .accounts: AccountsView()
        case .transactions: TransactionsView()
        case .forecast: ForecastView()
        case .history: HistoryView()
        case .tax: TaxSettingsView()
        case .account: AccountView()
        case .support: SupportView()
        case .admin: AdminView()
        case .backup: BackupView()
        case .updates:
            #if os(macOS)
            UpdatesView()
            #else
            EmptyView()
            #endif
        }
    }
}

/// A few related screens behind one menu item, with tabs on top.
struct GroupScreen: View {
    @EnvironmentObject private var store: Store
    let tabs: [SidebarItem]
    let keyPath: ReferenceWritableKeyPath<Store, SidebarItem>

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })) {
                ForEach(tabs) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: 560)
            store[keyPath: keyPath].screen
                .id(store[keyPath: keyPath])
        }
        .background(Palette.window)
    }
}

#if os(macOS)
struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var support: SupportCenter
    @State private var selection: SidebarItem? = .summary
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            // Header, list and footer stacked — as safe-area insets the sidebar list drew its last rows under the footer.
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HouseholdSwitcher { selection = .account }
                    .padding(.horizontal, 14)
                FamilySwitcher()
                Button { showSearch = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("חיפוש מסך")
                        Spacer()
                        Text(verbatim: "⌘K").font(.caption).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .help("חיפוש מסך (⌘K)")
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
            List(selection: $selection) {
                Label(SidebarItem.summary.title, systemImage: SidebarItem.summary.icon).tag(SidebarItem.summary)
                Label(SidebarItem.money.title, systemImage: SidebarItem.money.icon)
                    .badge(store.cardImportDue ? Text(verbatim: "ייבוא") : nil)
                    .tag(SidebarItem.money)
                Label(SidebarItem.budget.title, systemImage: SidebarItem.budget.icon).tag(SidebarItem.budget)
                Section("תכנון ותובנות") {
                    ForEach([SidebarItem.forecast, .history, .maaser, .owed, .trends, .insights]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("הגדרות") {
                    Label(SidebarItem.tax.title, systemImage: SidebarItem.tax.icon).tag(SidebarItem.tax)
                    Label(SidebarItem.account.title, systemImage: SidebarItem.account.icon).tag(SidebarItem.account)
                    Label(SidebarItem.support.title, systemImage: SidebarItem.support.icon)
                        .badge(support.unread)
                        .tag(SidebarItem.support)
                    if account.isAdmin {
                        Label(SidebarItem.admin.title, systemImage: SidebarItem.admin.icon)
                            .badge(support.adminUnread)
                            .tag(SidebarItem.admin)
                    }
                    Label(SidebarItem.backup.title, systemImage: SidebarItem.backup.icon).tag(SidebarItem.backup)
                    Label(SidebarItem.updates.title, systemImage: SidebarItem.updates.icon)
                        .badge(updater.updateAvailable || !updater.isInApplications ? Text(verbatim: "חדש") : nil)
                        .tag(SidebarItem.updates)
                }
            }
            .listStyle(.sidebar)
            Divider()
                VStack(alignment: .leading, spacing: 2) {
                    if let latest = updater.latest, updater.updateAvailable {
                        Button {
                            selection = .updates
                        } label: {
                            Label("עדכון זמין: \(latest.version)", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 10)
                    }
                    Text("עו״ש עכשיו")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: Fmt.moneyRounded(store.checkingNow))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .padding(.bottom, 6)
                    let picture = store.monthPicture
                    Text("נשאר בפועל")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: Fmt.moneyRounded(picture.remainingActual))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(picture.remainingActual >= 0 ? Color.green : Color.red)
                        .padding(.bottom, 6)
                    if !UserDefaults.standard.bool(forKey: Store.hideCardEstimateKey) {
                        Text("צפוי להישאר")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: Fmt.moneyRounded(picture.remaining))
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(picture.remaining >= 0 ? Color.green : Color.red)
                    }
                    Text(verbatim: "גרסה " + Diagnostics.appVersion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
            FamilyContextBar()
            (selection ?? .summary).screen
            }
        }
        .onChange(of: store.openScreen) { _, item in
            if let item { store.show(item); selection = item.home; store.openScreen = nil }
        }
        .sheet(isPresented: $showSearch) { ScreenSearchSheet() }
        .task {
            updater.check()
            await store.refreshRates()
            await store.refreshPrime()
            await store.refreshExchangeRates()
        }
        .onReceive(NotificationCenter.default.publisher(for: Platform.didBecomeActive)) { _ in
            updater.check()
            Task { await sync.sync() }
            Task { await store.refreshPrime(); await store.refreshExchangeRates() }
        }
    }
}
#endif

/// The search results: screens whose name, place, explanation or common words match the query.
struct ScreenSearchResults: View {
    @EnvironmentObject private var account: UserAccount
    let query: String
    let open: (SidebarItem) -> Void

    var results: [SidebarItem] { SidebarItem.searchable(isAdmin: account.isAdmin).filter { $0.matches(query) } }

    var body: some View {
        if results.isEmpty {
            Text("לא נמצא מסך כזה. נסה מילה אחרת, למשל ״משכורת״, ״אשראי״ או ״מעשר״.")
                .foregroundStyle(.secondary)
        }
        ForEach(results) { item in
            Button { open(item) } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .frame(width: 22)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.path)
                            .foregroundStyle(.primary)
                        if let intro = item.intro {
                            Text(intro)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

#if os(macOS)
/// ⌘K: type what you're looking for and jump to its screen.
struct ScreenSearchSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var account: UserAccount
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private func open(_ item: SidebarItem) {
        store.openScreen = item
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("איזה מסך לפתוח? למשל ״משכורת״, ״אשראי״, ״מעשר״", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit {
                        if let first = SidebarItem.searchable(isAdmin: account.isAdmin).first(where: { $0.matches(query) }) { open(first) }
                    }
            }
            .padding(14)
            Divider()
            List {
                ScreenSearchResults(query: query, open: open)
            }
            .listStyle(.plain)
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }
}
#endif

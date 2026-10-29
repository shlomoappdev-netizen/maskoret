import SwiftUI

@main
struct MaskoretApp: App {
    @StateObject private var store = Store()
    @StateObject private var insights = InsightsEngine()
    @StateObject private var account = UserAccount()
    @StateObject private var sync = ServerSync()
    #if os(macOS)
    @StateObject private var updater = Updater()
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup("מחשבון שכר") {
            ContentView()
                // Inside the environment objects below — it reads them.
                .serverSyncLifecycle()
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(insights)
                .environmentObject(sync)
                .environmentObject(account)
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
                // Inside the environment objects below — it reads them.
                .serverSyncLifecycle()
                .environmentObject(store)
                .environmentObject(insights)
                .environmentObject(sync)
                .environmentObject(account)
                .hebrew()
        }
        #endif
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case summary, incomes, deductions, expenses, card, accounts, transactions, forecast, history, maaser, owed, tracked, trends, insights, tax, account, admin, backup, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "סיכום"
        case .incomes: return "הכנסות"
        case .deductions: return "ניכויים"
        case .expenses: return "הוצאות קבועות"
        case .tracked: return "מעקב רכישות"
        case .trends: return "מגמות"
        case .maaser: return "מעשרות"
        case .owed: return "חייבים לי"
        case .insights: return "תובנות AI"
        case .card: return "כרטיס אשראי"
        case .accounts: return "חשבונות וחיסכון"
        case .transactions: return "תנועות"
        case .forecast: return "תחזית"
        case .history: return "חודשים"
        case .tax: return "נתוני מס"
        case .account: return "חשבון ומשק בית"
        case .admin: return "ניהול משתמשים"
        case .backup: return "גרסאות קודמות"
        case .updates: return "עדכונים"
        }
    }

    var icon: String {
        switch self {
        case .summary: return "chart.pie.fill"
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
        case .admin: return "person.2.badge.gearshape"
        case .backup: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        }
    }
}

extension SidebarItem {
    /// The screen for this item (shared by the Mac sidebar and the iPhone tabs).
    @ViewBuilder var screen: some View {
        switch self {
        case .summary: SummaryView()
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

#if os(macOS)
struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var account: UserAccount
    @State private var selection: SidebarItem? = .summary

    var body: some View {
        NavigationSplitView {
            // Header, list and footer stacked — as safe-area insets the sidebar list drew its last rows under the footer.
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HouseholdSwitcher { selection = .account }
                    .padding(.horizontal, 14)
                FamilySwitcher()
            }
            List(selection: $selection) {
                Section("החודש") {
                    ForEach([SidebarItem.summary, .incomes, .deductions, .expenses]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("הכסף שלי") {
                    ForEach([SidebarItem.accounts, .card, .transactions, .forecast, .history, .maaser, .owed]) { item in
                        Label(item.title, systemImage: item.icon)
                            .badge(item == .card && store.cardImportDue ? Text(verbatim: "ייבוא") : nil)
                            .tag(item)
                    }
                }
                Section("מעקב") {
                    ForEach([SidebarItem.tracked, .trends, .insights]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("הגדרות") {
                    Label(SidebarItem.tax.title, systemImage: SidebarItem.tax.icon).tag(SidebarItem.tax)
                    Label(SidebarItem.account.title, systemImage: SidebarItem.account.icon).tag(SidebarItem.account)
                    if account.isAdmin {
                        Label(SidebarItem.admin.title, systemImage: SidebarItem.admin.icon).tag(SidebarItem.admin)
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
                    Text("נשאר בסוף החודש")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let remaining = store.monthPicture.remaining
                    Text(verbatim: Fmt.moneyRounded(remaining))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(remaining >= 0 ? Color.green : Color.red)
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
        .task {
            updater.check()
            await store.refreshRates()
            await store.refreshPrime()
        }
        .onReceive(NotificationCenter.default.publisher(for: Platform.didBecomeActive)) { _ in
            updater.check()
            Task { await sync.sync() }
            Task { await store.refreshPrime() }
        }
    }
}
#endif

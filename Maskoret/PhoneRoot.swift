import SwiftUI

#if os(iOS)
/// iPhone / iPad: the main screens as tabs, everything else under "עוד".
struct PhoneRoot: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var support: SupportCenter
    @EnvironmentObject private var account: UserAccount
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: SidebarItem = .summary

    private static let tabs: [SidebarItem] = [.summary, .transactions, .card, .accounts]

    var body: some View {
        TabView(selection: $tab) {
            ForEach(PhoneRoot.tabs) { item in
                VStack(spacing: 0) {
                    FamilyContextBar()
                    item.screen
                }
                .tabItem { Label(item.title, systemImage: item.icon) }
                .badge(item == .card && store.cardImportDue ? Text(verbatim: "!") : nil)
                .tag(item)
            }
            MoreView()
                .tabItem { Label("עוד", systemImage: "ellipsis.circle") }
                .badge(sync.lastError != nil ? Text(verbatim: "!")
                       : support.unread + support.adminUnread > 0 ? Text(verbatim: "\(support.unread + support.adminUnread)") : nil)
                .tag(SidebarItem.updates)
        }
        .task {
            await store.refreshRates()
            await store.refreshPrime()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                    Task { await sync.sync() }
                Task { await store.refreshPrime() }
                Task { await support.refresh(isAdmin: account.isAdmin) }
            case .background:
                // Push the last changes before iOS suspends the app.
                let id = UIApplication.shared.beginBackgroundTask(withName: "sync")
                Task {
                    await sync.sync()
                    UIApplication.shared.endBackgroundTask(id)
                }
            default:
                break
            }
        }
    }
}

/// Every other screen, grouped like the Mac sidebar.
struct MoreView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var support: SupportCenter
    @State private var selection: SidebarItem?

    private let sections: [(String, [SidebarItem])] = [
        ("החודש", [.incomes, .deductions, .expenses]),
        ("הכסף שלי", [.forecast, .history, .maaser, .owed]),
        ("מעקב", [.tracked, .trends, .insights]),
        ("הגדרות", [.account, .support, .tax, .backup])
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    HouseholdSwitcher { selection = .account }
                    FamilySwitcher()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("עו״ש עכשיו").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: Fmt.moneyRounded(store.checkingNow))
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                        }
                        Spacer()
                        let remaining = store.monthPicture.remaining
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("נשאר בסוף החודש").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: Fmt.moneyRounded(remaining))
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(remaining >= 0 ? Color.green : Color.red)
                        }
                    }
                }
                if account.isAdmin {
                    Section("מנהל") {
                        NavigationLink(value: SidebarItem.admin) {
                            Label(SidebarItem.admin.title, systemImage: SidebarItem.admin.icon)
                                .badge(support.adminUnread)
                        }
                    }
                }
                ForEach(sections, id: \.0) { title, items in
                    Section(title) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                Label(item.title, systemImage: item.icon)
                                    .badge(item == .account && sync.lastError != nil ? Text(verbatim: "!")
                                           : item == .support && support.unread > 0 ? Text(verbatim: "\(support.unread)") : nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("עוד")
        } detail: {
            if let selection {
                VStack(spacing: 0) {
                    FamilyContextBar()
                    selection.screen
                }
            } else {
                ContentUnavailableView("בחר מסך", systemImage: "sidebar.left")
            }
        }
    }
}
#endif

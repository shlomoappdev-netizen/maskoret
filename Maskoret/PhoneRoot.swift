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

    static let tabs: [SidebarItem] = [.summary, .money, .budget]

    var body: some View {
        TabView(selection: $tab) {
            ForEach(PhoneRoot.tabs) { item in
                VStack(spacing: 0) {
                    FamilyContextBar()
                    item.screen
                }
                .tabItem { Label(item.title, systemImage: item.icon) }
                .badge(item == .money && store.cardImportDue ? Text(verbatim: "!") : nil)
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
        .onChange(of: store.openScreen) { _, item in
            guard let item else { return }
            store.show(item)
            if PhoneRoot.tabs.contains(item.home) {
                tab = item.home
                store.openScreen = nil
            } else {
                tab = .updates   // "עוד" opens it
            }
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
        ("תכנון ותובנות", [.forecast, .history, .maaser, .owed, .trends, .insights]),
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
                        let picture = store.monthPicture
                        VStack(alignment: .leading, spacing: 2) {
                            Text("נשאר בפועל").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: Fmt.moneyRounded(picture.remainingActual))
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(picture.remainingActual >= 0 ? Color.green : Color.red)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("צפוי להישאר").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: Fmt.moneyRounded(picture.remaining))
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(picture.remaining >= 0 ? Color.green : Color.red)
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
                Section {
                } footer: {
                    Text(verbatim: "מחשבון שכר · גרסה " + Diagnostics.appVersion)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("עוד")
            .onChange(of: store.openScreen) { _, item in
                if let item, !PhoneRoot.tabs.contains(item.home) { selection = item; store.openScreen = nil }
            }
            .onAppear {
                if let item = store.openScreen, !PhoneRoot.tabs.contains(item.home) { selection = item; store.openScreen = nil }
            }
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

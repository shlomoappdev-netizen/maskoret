import SwiftUI
import Supabase

/// "ניהול משתמשים": subscribers and support, for the app's owner only.
/// Everything is searched and paged on the server, so it stays fast with thousands of subscribers.
/// A subscriber's card shows their account, the households they own or can access, and their support threads —
/// never the financial data itself.
struct AdminView: View {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var support: SupportCenter

    enum Tab: Hashable { case subscribers, inbox, tasks }
    @State private var tab: Tab = .subscribers
    @State private var stats: AdminStats?

    var body: some View {
        NavigationStack {
            Group {
                if !account.isAdmin {
                    Text("המסך הזה זמין רק למנהל המערכת.").foregroundStyle(.secondary).padding()
                } else {
                    VStack(spacing: 0) {
                        statsBar
                        Picker("", selection: $tab) {
                            Text("מנויים").tag(Tab.subscribers)
                            Text(support.adminUnread > 0 ? "פניות (\(support.adminUnread))" : "פניות").tag(Tab.inbox)
                            Text("משימות פיתוח").tag(Tab.tasks)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                        switch tab {
                        case .subscribers: AdminSubscribersList()
                        case .inbox: AdminInboxList()
                        case .tasks: AdminDevTasksList()
                        }
                    }
                }
            }
            .navigationTitle("ניהול משתמשים")
            .navigationDestination(for: AdminRoute.self) { route in
                switch route {
                case .user(let id): AdminUserCard(userID: id)
                case .thread(let id): SupportChatView(threadID: id, asAdmin: true)
                }
            }
            .task { await loadStats() }
            .onChange(of: support.adminUnread) { _, _ in Task { await loadStats() } }
        }
    }

    private var statsBar: some View {
        HStack {
            stat("מנויים", stats?.users)
            stat("חדשים השבוע", stats?.new_7d)
            stat("פעילים השבוע", stats?.active_7d)
            stat("משקי בית", stats?.households)
            stat("פניות פתוחות", stats?.open_threads)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value.map(String.init) ?? "—").font(.title3.weight(.bold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadStats() async {
        guard account.isAdmin else { return }
        stats = try? await Task { try await AdminAPI.stats() }.value
    }
}

enum AdminRoute: Hashable {
    case user(UUID)
    case thread(UUID)
}

// MARK: - Subscribers

private struct AdminSubscribersList: View {
    @State private var query = ""
    @State private var filter = "all"
    @State private var users: [AdminAPI.UserRow] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    private static let pageSize = 50
    private let filters = [("all", "הכול"), ("unconfirmed", "לא אומתו"), ("open_threads", "עם פניות פתוחות"), ("blocked", "חסומים")]

    var body: some View {
        List {
            Section {
                Picker("הצג", selection: $filter) {
                    ForEach(filters, id: \.0) { Text($0.1).tag($0.0) }
                }
                if let error {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            } footer: {
                Text("חיפוש לפי מספר מנוי, מייל, שם, מזהה חשבון או שם של משק בית.")
            }
            Section("\(total) מנויים") {
                ForEach(users) { user in
                    NavigationLink(value: AdminRoute.user(user.id)) {
                        AdminUserRowView(user: user)
                    }
                }
                if users.count < total {
                    Button(loading ? "טוען…" : "עוד \(min(Self.pageSize, total - users.count))") {
                        Task { await load(append: true) }
                    }
                    .disabled(loading)
                }
            }
        }
        .searchable(text: $query, prompt: "מספר מנוי, מייל, שם…")
        .task(id: "\(query)|\(filter)") {
            // Wait for the typing to settle before asking the server.
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load(append: false)
        }
        .refreshable { await load(append: false) }
    }

    private func load(append: Bool) async {
        loading = true
        defer { loading = false }
        let offset = append ? users.count : 0
        let (q, f) = (query, filter)
        do {
            let page = try await Task { try await AdminAPI.search(q, filter: f, limit: Self.pageSize, offset: offset) }.value
            users = append ? users + page.users : page.users
            total = page.total
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = UserAccount.describe(error)
        }
    }
}

private struct AdminUserRowView: View {
    let user: AdminAPI.UserRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: user.display_name.isEmpty ? (user.email ?? "—") : user.display_name)
                    .font(.body.weight(.medium)).lineLimit(1)
                Text(verbatim: "#\(user.member_no)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !user.confirmed { AdminBadge(text: "לא אומת", color: .orange) }
                if user.blocked { AdminBadge(text: "חסום", color: .red) }
                if user.open_threads > 0 { AdminBadge(text: "\(user.open_threads) פניות", color: .accentColor) }
            }
            if !user.display_name.isEmpty, let email = user.email {
                Text(verbatim: email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(verbatim: "🏠 \(user.owned) בבעלות · \(user.shared) מורשה גישה · כניסה אחרונה "
                 + (user.last_sign_in_at.map(AdminAPI.date) ?? "—"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct AdminBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - Inbox

private struct AdminInboxList: View {
    @EnvironmentObject private var support: SupportCenter
    @State private var status = "open"
    @State private var query = ""
    @State private var threads: [AdminAPI.InboxThread] = []
    @State private var total = 0
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("הצג", selection: $status) {
                    Text("פתוחות").tag("open")
                    Text("סגורות").tag("closed")
                    Text("הכול").tag("all")
                }
                .pickerStyle(.segmented)
                if let error {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            }
            Section("\(total) פניות") {
                ForEach(threads) { t in
                    NavigationLink(value: AdminRoute.thread(t.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            ThreadRow(thread: t.thread, unread: t.admin_unread,
                                      subtitle: "#\(t.member_no) \(t.display_name.isEmpty ? (t.email ?? "") : t.display_name)")
                            if let preview = t.preview {
                                Text(verbatim: preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "מספר מנוי, מייל, נושא…")
        .task(id: "\(status)|\(query)|\(support.adminUnread)") {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        let (s, q) = (status, query)
        do {
            let page = try await Task { try await AdminAPI.inbox(status: s, query: q) }.value
            threads = page.threads
            total = page.total
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = UserAccount.describe(error)
        }
    }
}

// MARK: - Development tasks

/// Code fixes approved from tickets. They wait for a Claude Code session in the project on the Mac: it lists the
/// open ones when it starts, and /support handles them. A notification on the Mac announces each new one.
private struct AdminDevTasksList: View {
    @State private var status = "open"
    @State private var tasks: [DevTask] = []
    @State private var expanded: Set<Int64> = []
    @State private var error: String?
    @State private var channel: RealtimeChannelV2?

    var body: some View {
        List {
            Section {
                Picker("הצג", selection: $status) {
                    Text("פתוחות").tag("open")
                    Text("בוצעו").tag("done")
                    Text("הכול").tag("all")
                }
                .pickerStyle(.segmented)
                if let error {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            } footer: {
                Text("משימה נרשמת כשבוחרים בהצעה של Claude לתיקון בקוד. על המק תקפוץ התראה, וכשתפתח את Claude Code בתיקיית הפרויקט הוא יציג את המשימות הפתוחות ויציע לטפל בהן (או הקלד ‎/support).")
            }
            Section("\(shown.count) משימות") {
                if shown.isEmpty {
                    Text(status == "open" ? "אין משימות פתוחות." : "אין משימות.").foregroundStyle(.secondary)
                }
                ForEach(shown) { task in
                    row(task)
                }
            }
        }
        .task { await start() }
        .onDisappear {
            if let channel { Task { await supabase.removeChannel(channel) } }
        }
        .refreshable { await load() }
    }

    private var shown: [DevTask] {
        switch status {
        case "open": tasks.filter { $0.status == "open" }
        case "done": tasks.filter { $0.status != "open" }
        default: tasks
        }
    }

    private func row(_ task: DevTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) } }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: task.status == "open" ? "hammer.fill" : (task.status == "done" ? "checkmark.circle.fill" : "xmark.circle"))
                        .foregroundStyle(task.status == "open" ? Color.indigo : (task.status == "done" ? Color.green : Color.secondary))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "#\(task.id) \(task.title)").font(.callout.weight(.semibold))
                        Text(verbatim: AdminAPI.date(task.created_at) + (task.status == "open" ? " · ממתינה ל-Claude Code" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(task.id) ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(task.id) {
                Text(verbatim: task.details).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let thread = task.thread_id {
                        NavigationLink(value: AdminRoute.thread(thread)) {
                            Label("לפנייה", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    Spacer()
                    if task.status == "open" {
                        Button("סמן כבוצעה") { setStatus(task, "done") }
                        Button("ביטול המשימה", role: .destructive) { setStatus(task, "dropped") }
                    } else {
                        Button("החזרה לפתוחות") { setStatus(task, "open") }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func setStatus(_ task: DevTask, _ status: String) {
        Task {
            do {
                try await AdminAPI.setTaskStatus(task.id, status)
                await load()
            } catch {
                self.error = UserAccount.describe(error)
            }
        }
    }

    private func start() async {
        await load()
        let channel = supabase.channel("admin-dev-tasks")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "dev_tasks")
        self.channel = channel
        await channel.subscribe()
        for await _ in changes { await load() }
    }

    private func load() async {
        do {
            tasks = try await Task { try await AdminAPI.devTasks() }.value
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = UserAccount.describe(error)
        }
    }
}

// MARK: - A subscriber's card

private struct AdminUserCard: View {
    let userID: UUID

    @EnvironmentObject private var account: UserAccount
    @State private var user: AdminAPI.UserDetail?
    @State private var error: String?
    @State private var confirm: Confirmation?

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let action: () async throws -> Void
    }

    var body: some View {
        Form {
            if let error {
                Text(error).foregroundStyle(.orange).font(.callout)
            }
            if let user {
                identity(user)
                let owned = user.households.filter { $0.role == "owner" }
                let shared = user.households.filter { $0.role != "owner" }
                Section("משקי בית בבעלותו (\(owned.count))") {
                    if owned.isEmpty { Text("אין").foregroundStyle(.secondary) }
                    ForEach(owned) { household(owned: true, $0, of: user) }
                }
                Section("מורשה גישה ל־ (\(shared.count))") {
                    if shared.isEmpty { Text("אין").foregroundStyle(.secondary) }
                    ForEach(shared) { household(owned: false, $0, of: user) }
                }
                Section("פניות (\(user.threads.count))") {
                    if user.threads.isEmpty { Text("אין פניות").foregroundStyle(.secondary) }
                    ForEach(user.threads) { t in
                        NavigationLink(value: AdminRoute.thread(t.id)) {
                            ThreadRow(thread: t.asThread(user: user.id), unread: t.admin_unread)
                        }
                    }
                }
                actions(user)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(user.map { $0.display_name.isEmpty ? ($0.email ?? "מנוי") : $0.display_name } ?? "מנוי")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button(c.button, role: .destructive) { run(c.action) }
            Button("ביטול", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    private func identity(_ user: AdminAPI.UserDetail) -> some View {
        Section {
            copyRow("מספר מנוי", String(user.member_no))
            copyRow("מייל", user.email ?? "—")
            if !user.display_name.isEmpty { LabeledContent("שם", value: user.display_name) }
            copyRow("מזהה חשבון", user.id.uuidString.lowercased(), small: true)
            LabeledContent("התחברות") {
                Text(verbatim: user.providers.map { $0 == "google" ? "Google" : ($0 == "email" ? "מייל וסיסמה" : $0) }
                        .joined(separator: ", "))
            }
            LabeledContent("סטטוס") {
                HStack(spacing: 6) {
                    AdminBadge(text: user.confirmed ? "מאומת" : "לא אומת", color: user.confirmed ? .green : .orange)
                    if user.blocked { AdminBadge(text: "חסום", color: .red) }
                }
            }
            LabeledContent("נרשם", value: AdminAPI.date(user.created_at))
            LabeledContent("כניסה אחרונה", value: user.last_sign_in_at.map(AdminAPI.date) ?? "—")
            LabeledContent("מכשירים מחוברים", value: "\(user.sessions)")
        }
    }

    private func copyRow(_ title: String, _ value: String, small: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(verbatim: value)
                    .font(small ? .caption.monospaced() : .body.monospacedDigit())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    Platform.copy(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("העתקה")
            }
        }
    }

    @ViewBuilder
    private func household(owned: Bool, _ h: AdminAPI.UserDetail.Household, of user: AdminAPI.UserDetail) -> some View {
        DisclosureGroup {
            ForEach(h.members) { m in
                HStack {
                    NavigationLink(value: AdminRoute.user(m.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: m.display_name.isEmpty ? (m.email ?? "—") : m.display_name)
                                Text(verbatim: "#\(m.member_no)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                AdminBadge(text: m.role == "owner" ? "בעלים" : "מורשה גישה",
                                           color: m.role == "owner" ? .accentColor : .secondary)
                            }
                            if !m.display_name.isEmpty, let email = m.email {
                                Text(verbatim: email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if m.role != "owner" {
                        Menu {
                            Button("העברת הבעלות אליו") {
                                confirm = .init(title: "להעביר את \(h.name) לבעלות \(m.email ?? "")?",
                                                message: "הבעלים הנוכחי יישאר עם גישה למשק הבית.",
                                                button: "העברת בעלות") {
                                    try await AdminAPI.transferOwner(household: h.id, to: m.id)
                                }
                            }
                            Button("הסרה ממשק הבית", role: .destructive) {
                                confirm = .init(title: "להסיר את \(m.email ?? "") מ\(h.name)?",
                                                message: "הוא יאבד את הגישה לנתונים של משק הבית הזה.",
                                                button: "הסרה") {
                                    try await AdminAPI.removeMember(household: h.id, user: m.id)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            if owned {
                Button("מחיקת משק הבית", role: .destructive) {
                    confirm = .init(title: "למחוק את משק הבית \(h.name)?",
                                    message: "משק הבית, הנתונים שלו וכל הגרסאות הקודמות יימחקו מהשרת לכל \(h.members.count) החברים בו.",
                                    button: "מחיקה") {
                        try await AdminAPI.deleteHousehold(h.id)
                    }
                }
            } else {
                Button("הסרת הגישה שלו", role: .destructive) {
                    confirm = .init(title: "להסיר את הגישה ל\(h.name)?",
                                    message: "המנוי יאבד את הגישה לנתונים של משק הבית הזה.",
                                    button: "הסרה") {
                        try await AdminAPI.removeMember(household: h.id, user: user.id)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: h.name).font(.body.weight(.medium))
                let owner = h.members.first { $0.role == "owner" }
                Text(verbatim: (owned ? "" : "בעלים: \(owner?.email ?? "—") · ")
                     + "\(h.members.count) חברים · "
                     + (h.size_bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                     + " · \(h.versions) גרסאות")
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: "עודכן " + (h.updated_at.map(AdminAPI.date) ?? "—") + (h.device.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ user: AdminAPI.UserDetail) -> some View {
        Section("פעולות") {
            if !user.confirmed {
                Button("אישור המייל ידנית") {
                    run { try await AdminAPI.confirmEmail(user.id) }
                }
            }
            Button("ניתוק מכל המכשירים") {
                confirm = .init(title: "לנתק את \(user.email ?? "") מכל המכשירים?",
                                message: "הוא יצטרך להתחבר מחדש. הנתונים לא נמחקים.", button: "ניתוק") {
                    try await AdminAPI.signOut(user.id)
                }
            }
            .disabled(user.id == account.userID)
            Button(user.blocked ? "ביטול החסימה" : "חסימת החשבון") {
                if user.blocked {
                    run { try await AdminAPI.setBlocked(user.id, false) }
                } else {
                    confirm = .init(title: "לחסום את \(user.email ?? "")?",
                                    message: "הוא ינותק מכל המכשירים ולא יוכל להתחבר עד שתבטל את החסימה. הנתונים נשמרים.",
                                    button: "חסימה") {
                        try await AdminAPI.setBlocked(user.id, true)
                    }
                }
            }
            .disabled(user.id == account.userID)
            Button("מחיקת החשבון", role: .destructive) {
                confirm = .init(title: "למחוק לצמיתות את \(user.email ?? "")?",
                                message: "החשבון יימחק. משקי בית שהוא לבד בהם יימחקו; משקי בית משותפים יעברו לחבר הוותיק ביותר.",
                                button: "מחיקה לצמיתות") {
                    try await AdminAPI.deleteUser(user.id)
                }
            }
            .disabled(user.id == account.userID)
        }
    }

    private func load() async {
        do {
            let id = userID
            user = try await Task { try await AdminAPI.detail(id) }.value
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = UserAccount.describe(error)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                await load()
            } catch {
                self.error = UserAccount.describe(error)
            }
        }
    }
}

// MARK: - Server calls

enum AdminAPI {
    struct UserRow: Decodable, Identifiable {
        let id: UUID
        let member_no: Int64
        let email: String?
        let display_name: String
        let created_at: String
        let last_sign_in_at: String?
        let confirmed: Bool
        let blocked: Bool
        let owned: Int
        let shared: Int
        let open_threads: Int
    }

    struct SearchPage: Decodable {
        let total: Int
        let users: [UserRow]
    }

    struct UserDetail: Decodable {
        struct Member: Decodable, Identifiable {
            let id: UUID
            let role: String
            let email: String?
            let display_name: String
            let member_no: Int64
        }
        struct Household: Decodable, Identifiable {
            let id: UUID
            let name: String
            let role: String
            let revision: Int64
            let updated_at: String?
            let device: String?
            let size_bytes: Int?
            let versions: Int
            let members: [Member]
        }
        struct Thread: Decodable, Identifiable {
            let id: UUID
            let subject: String
            let category: String
            let status: String
            let created_at: String
            let last_message_at: String
            let admin_unread: Int

            func asThread(user: UUID) -> SupportThread {
                SupportThread(id: id, user_id: user, subject: subject, category: category, status: status,
                              created_at: created_at, last_message_at: last_message_at, user_unread: 0,
                              admin_unread: admin_unread)
            }
        }
        let id: UUID
        let member_no: Int64
        let email: String?
        let display_name: String
        let created_at: String
        let last_sign_in_at: String?
        let confirmed: Bool
        let blocked: Bool
        let providers: [String]
        let sessions: Int
        let households: [Household]
        let threads: [Thread]
    }

    struct InboxThread: Decodable, Identifiable {
        let id: UUID
        let user_id: UUID
        let subject: String
        let category: String
        let status: String
        let created_at: String
        let last_message_at: String
        let admin_unread: Int
        let user_unread: Int
        let email: String?
        let display_name: String
        let member_no: Int64
        let preview: String?

        var thread: SupportThread {
            SupportThread(id: id, user_id: user_id, subject: subject, category: category, status: status,
                          created_at: created_at, last_message_at: last_message_at, user_unread: user_unread,
                          admin_unread: admin_unread)
        }
    }

    struct InboxPage: Decodable {
        let total: Int
        let threads: [InboxThread]
    }

    static func stats() async throws -> AdminStats {
        try await supabase.rpc("admin_stats").decoded(AdminStats.self)
    }

    static func search(_ query: String, filter: String, limit: Int, offset: Int) async throws -> SearchPage {
        struct Params: Encodable { let q: String, p_filter: String, p_limit: Int, p_offset: Int }
        return try await supabase.rpc("admin_search_users",
                                      params: Params(q: query, p_filter: filter, p_limit: limit, p_offset: offset))
            .decoded(SearchPage.self)
    }

    static func detail(_ id: UUID) async throws -> UserDetail {
        try await supabase.rpc("admin_user_detail", params: ["target": id]).decoded(UserDetail.self)
    }

    static func inbox(status: String, query: String) async throws -> InboxPage {
        struct Params: Encodable { let p_status: String, q: String, p_limit: Int, p_offset: Int }
        return try await supabase.rpc("admin_support_inbox", params: Params(p_status: status, q: query, p_limit: 100, p_offset: 0))
            .decoded(InboxPage.self)
    }

    static func setBlocked(_ id: UUID, _ blocked: Bool) async throws {
        struct Params: Encodable { let target: UUID, p_blocked: Bool }
        try await supabase.rpc("admin_set_blocked", params: Params(target: id, p_blocked: blocked)).execute()
    }

    static func signOut(_ id: UUID) async throws {
        try await supabase.rpc("admin_sign_out_user", params: ["target": id]).execute()
    }

    static func confirmEmail(_ id: UUID) async throws {
        try await supabase.rpc("admin_confirm_email", params: ["target": id]).execute()
    }

    static func removeMember(household: UUID, user: UUID) async throws {
        struct Params: Encodable { let hid: UUID, member: UUID }
        try await supabase.rpc("admin_remove_member", params: Params(hid: household, member: user)).execute()
    }

    static func transferOwner(household: UUID, to user: UUID) async throws {
        struct Params: Encodable { let hid: UUID, new_owner: UUID }
        try await supabase.rpc("admin_transfer_owner", params: Params(hid: household, new_owner: user)).execute()
    }

    static func deleteHousehold(_ id: UUID) async throws {
        try await supabase.rpc("admin_delete_household", params: ["hid": id]).execute()
    }

    static func deleteUser(_ id: UUID) async throws {
        try await supabase.rpc("admin_delete_user", params: ["target": id]).execute()
    }

    // MARK: Claude's proposals

    /// Everything Claude proposed in a thread, oldest first (the open one is the last, if any).
    static func proposals(thread: UUID) async throws -> [SupportProposal] {
        try await supabase.from("support_proposals").select()
            .eq("thread_id", value: thread).order("id", ascending: true)
            .decoded([SupportProposal].self)
    }

    static func questions(thread: UUID) async throws -> [SupportAIQuestion] {
        try await supabase.from("support_ai_questions").select()
            .eq("thread_id", value: thread).order("id", ascending: true)
            .decoded([SupportAIQuestion].self)
    }

    /// Asks Claude about the thread; the answer arrives as the next proposal.
    static func ask(thread: UUID, question: String) async throws {
        struct Params: Encodable { let p_thread: UUID, p_question: String }
        try await supabase.rpc("admin_ask_claude", params: Params(p_thread: thread, p_question: question)).execute()
    }

    static func devTasks() async throws -> [DevTask] {
        try await supabase.from("dev_tasks").select().order("id", ascending: false).limit(200)
            .decoded([DevTask].self)
    }

    static func setTaskStatus(_ task: Int64, _ status: String) async throws {
        struct Params: Encodable { let p_task: Int64, p_status: String }
        try await supabase.rpc("admin_set_dev_task_status", params: Params(p_task: task, p_status: status)).execute()
    }

    static func decide(_ proposal: Int64, status: String, option: String? = nil) async throws {
        struct Params: Encodable { let p_proposal: Int64, p_status: String, p_option: String? }
        try await supabase.rpc("admin_decide_proposal", params: Params(p_proposal: proposal, p_status: status, p_option: option))
            .execute()
    }

    static func setAIMode(thread: UUID, on: Bool) async throws {
        struct Params: Encodable { let p_thread: UUID, p_mode: String }
        try await supabase.rpc("admin_set_ai_mode", params: Params(p_thread: thread, p_mode: on ? "on" : "off")).execute()
    }

    static func requestProposal(thread: UUID) async throws {
        try await supabase.rpc("admin_request_proposal", params: ["p_thread": thread]).execute()
    }

    /// Does what a chosen option asks for besides the reply.
    static func perform(_ option: SupportProposal.Option, thread: SupportThread) async throws {
        switch option.action {
        case "confirm_email": try await confirmEmail(thread.user_id)
        case "sign_out_user": try await signOut(thread.user_id)
        case "dev_task":
            struct Params: Encodable { let p_thread: UUID, p_title: String, p_details: String }
            try await supabase.rpc("admin_add_dev_task",
                                   params: Params(p_thread: thread.id, p_title: option.task_title ?? option.title,
                                                  p_details: option.task_details ?? option.explanation)).execute()
        default: break
        }
    }

    static func date(_ text: String) -> String {
        guard let d = ISO8601DateFormatter.flexible(text) else { return "—" }
        return d.formatted(.dateTime.day().month().year().hour().minute().locale(Fmt.locale))
    }
}

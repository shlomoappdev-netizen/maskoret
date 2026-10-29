import SwiftUI

/// "ניהול משתמשים": every account and household on the server — for the app's owner only.
/// Shows who uses the app and lets the owner remove an account or a household; never the financial data itself.
struct AdminView: View {
    @EnvironmentObject private var account: UserAccount

    @State private var overview: UserAccount.AdminOverview?
    @State private var error: String?
    @State private var loading = false
    @State private var search = ""
    @State private var deletingUser: UserAccount.AdminOverview.User?
    @State private var deletingHousehold: UserAccount.AdminOverview.Household?

    private var users: [UserAccount.AdminOverview.User] {
        let all = overview?.users ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { ($0.email ?? "").lowercased().contains(q) || $0.display_name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !account.isAdmin {
                    Text("המסך הזה זמין רק למנהל המערכת.").foregroundStyle(.secondary)
                } else {
                    summarySection
                    usersSection
                    householdsSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("ניהול משתמשים")
            .searchable(text: $search, prompt: "חיפוש לפי מייל או שם")
            .task { await load() }
            .refreshable { await load() }
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("רענן", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
            .confirmationDialog("למחוק את החשבון \(deletingUser?.email ?? "")?",
                                isPresented: Binding(get: { deletingUser != nil }, set: { if !$0 { deletingUser = nil } }),
                                titleVisibility: .visible, presenting: deletingUser) { user in
                Button("מחק את החשבון", role: .destructive) {
                    act { try await account.adminDeleteUser(user.id) }
                }
                Button("ביטול", role: .cancel) {}
            } message: { _ in
                Text("החשבון יימחק לצמיתות. משקי בית שהוא היה לבד בהם יימחקו; משקי בית משותפים יעברו לחבר הוותיק ביותר.")
            }
            .confirmationDialog("למחוק את משק הבית \(deletingHousehold?.name ?? "")?",
                                isPresented: Binding(get: { deletingHousehold != nil }, set: { if !$0 { deletingHousehold = nil } }),
                                titleVisibility: .visible, presenting: deletingHousehold) { household in
                Button("מחק את משק הבית", role: .destructive) {
                    act { try await account.adminDeleteHousehold(household.id) }
                }
                Button("ביטול", role: .cancel) {}
            } message: { h in
                Text("משק הבית והנתונים שלו יימחקו מהשרת לכל \(h.member_count) החברים בו. עותק נשאר רק במכשירים שלהם.")
            }
        }
    }

    // MARK: Sections

    private var summarySection: some View {
        Section {
            HStack {
                stat("משתמשים", "\(overview?.users.count ?? 0)")
                stat("מאומתים", "\(overview?.users.filter(\.confirmed).count ?? 0)")
                stat("משקי בית", "\(overview?.households.count ?? 0)")
            }
            if let error {
                Text(error).foregroundStyle(.orange).font(.callout)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        } footer: {
            Text("כאן רואים מי משתמש באפליקציה ואת משקי הבית שלהם. הנתונים הכספיים עצמם לא מוצגים.")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value).font(.title2.weight(.bold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var usersSection: some View {
        Section("משתמשים (\(users.count))") {
            ForEach(users) { user in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: user.email ?? "—").font(.body.weight(.medium))
                            if !user.confirmed {
                                Text("לא אומת")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                            }
                            if user.id == account.userID {
                                Text("אתה").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if !user.display_name.isEmpty {
                            Text(verbatim: user.display_name).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: "נרשם " + date(user.created_at)
                             + " · כניסה אחרונה " + (user.last_sign_in_at.map(date) ?? "—"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !user.households.isEmpty {
                            Text(verbatim: "🏠 " + user.households.map { $0.name + ($0.role == "owner" ? " (בעלים)" : "") }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if user.id != account.userID {
                        Button(role: .destructive) {
                            deletingUser = user
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("מחיקת החשבון")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var householdsSection: some View {
        Section("משקי בית (\(overview?.households.count ?? 0))") {
            ForEach(overview?.households ?? []) { h in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: h.name).font(.body.weight(.medium))
                        Text(verbatim: "\(h.member_count) חברים · גרסה \(h.revision) · "
                             + (h.size_bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "עודכן " + (h.updated_at.map(date) ?? "—") + (h.device.map { " · " + $0 } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        deletingHousehold = h
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("מחיקת משק הבית")
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Helpers

    private func date(_ text: String) -> String {
        guard let d = ISO8601DateFormatter.flexible(text) else { return "—" }
        return d.formatted(.dateTime.day().month().year().hour().minute().locale(Fmt.locale))
    }

    private func load() async {
        guard account.isAdmin else { return }
        loading = true
        defer { loading = false }
        do {
            overview = try await account.adminOverview()
            error = nil
        } catch {
            self.error = UserAccount.describe(error)
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
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

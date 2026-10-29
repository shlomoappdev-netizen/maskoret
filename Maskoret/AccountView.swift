import SwiftUI

/// "חשבון ומשק בית": sync status, the household on screen, its members and invites, and the account.
struct AccountView: View {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var sync: ServerSync

    @State private var members: [HouseholdMember] = []
    @State private var invite: HouseholdInvite?
    @State private var joining = false
    @State private var creating = false
    @State private var renaming = false
    @State private var changingPassword = false
    @State private var editingName = false
    @State private var confirmSignOut = false
    @State private var confirmLeave = false
    @State private var confirmDeleteHousehold = false
    @State private var confirmDeleteAccount = false
    @State private var confirmDeleteAccountAgain = false
    @State private var removing: HouseholdMember?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if account.isSignedIn {
                    Form {
                        statusSection
                        householdSection
                        membersSection
                        accountSection
                    }
                    .formStyle(.grouped)
                } else {
                    VStack(spacing: 0) {
                        Text("התחבר כדי להמשיך להשתמש באפליקציה.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                        AuthView()
                    }
                }
            }
            .navigationTitle("חשבון ומשק בית")
            .task(id: account.activeHouseholdID) { await loadMembers() }
            .sheet(isPresented: $joining) { JoinHouseholdSheet() }
            .sheet(isPresented: $creating) { NewHouseholdSheet() }
            .sheet(isPresented: $renaming) {
                if let h = account.activeHousehold { RenameHouseholdSheet(household: h) }
            }
            .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
            .sheet(isPresented: $editingName) { DisplayNameSheet() }
            .sheet(item: Binding(get: { invite.map { InviteBox(invite: $0) } }, set: { if $0 == nil { invite = nil } })) { box in
                InviteSheet(invite: box.invite, householdName: account.activeHousehold?.name ?? "")
            }
            .confirmationDialog("להתנתק?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("התנתק והשאר את הנתונים במכשיר") { signOut(clearDevice: false) }
                Button("התנתק ומחק את הנתונים מהמכשיר", role: .destructive) { signOut(clearDevice: true) }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text("הנתונים נשארים שמורים בשרת. אם תמחק אותם מהמכשיר, נשמר קודם גיבוי מקומי.")
            }
            .confirmationDialog("לצאת ממשק הבית?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("צא ממשק הבית", role: .destructive) { act { if let id = account.activeHouseholdID { try await account.leave(id) } } }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text("לא תוכל לראות יותר את הנתונים שלו (עותק נשאר במכשיר). כדי לחזור צריך הזמנה חדשה.")
            }
            .confirmationDialog("למחוק את משק הבית?", isPresented: $confirmDeleteHousehold, titleVisibility: .visible) {
                Button("מחק לכל החברים", role: .destructive) { act { if let id = account.activeHouseholdID { try await account.delete(id) } } }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text("משק הבית והנתונים שלו יימחקו מהשרת לכל החברים. עותק נשאר במכשיר הזה.")
            }
            .confirmationDialog("להסיר את \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { m in
                Button("הסר ממשק הבית", role: .destructive) {
                    act { if let id = account.activeHouseholdID { try await account.removeMember(m.user_id, from: id); await loadMembers() } }
                }
                Button("ביטול", role: .cancel) {}
            }
            .confirmationDialog("למחוק את החשבון?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("המשך למחיקה", role: .destructive) { confirmDeleteAccountAgain = true }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text("החשבון יימחק לצמיתות. משקי בית שרק אתה חבר בהם יימחקו מהשרת; משקי בית משותפים יעברו לחבר הוותיק ביותר.")
            }
            .alert("בטוח? אי אפשר לבטל את זה.", isPresented: $confirmDeleteAccountAgain) {
                Button("מחק את החשבון", role: .destructive) { deleteAccount() }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text("הנתונים במכשיר הזה נשמרים כגיבוי. אחרי המחיקה אפשר לפתוח חשבון חדש.")
            }
        }
    }

    private struct InviteBox: Identifiable {
        let invite: HouseholdInvite
        var id: String { invite.code }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: sync.lastError == nil ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                    .font(.title)
                    .foregroundStyle(sync.lastError == nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sync.lastError == nil ? "מסונכרן עם השרת" : "יש בעיה בסנכרון").font(.headline)
                    if let error = sync.lastError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    } else if !sync.status.isEmpty {
                        Text(sync.status).font(.callout).foregroundStyle(.secondary)
                    }
                    if let last = sync.lastSync {
                        Text(verbatim: "סנכרון אחרון: " + last.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if sync.isSyncing { ProgressView().controlSize(.small) }
            }
            Button {
                Task { await sync.sync() }
            } label: {
                Label("סנכרן עכשיו", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isSyncing)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var householdSection: some View {
        Section {
            if account.households.count > 1 {
                Picker("משק הבית שמוצג", selection: Binding(
                    get: { account.activeHouseholdID ?? account.households.first?.id ?? UUID() },
                    set: { account.activeHouseholdID = $0 })) {
                    ForEach(account.households) { h in Text(h.name).tag(h.id) }
                }
            } else if let h = account.activeHousehold {
                RateLine(title: "משק הבית", value: h.name)
            }
            if let h = account.activeHousehold {
                if h.isOwner {
                    Button {
                        act { invite = try await account.createInvite(for: h.id) }
                    } label: {
                        Label("הזמן לבית הזה", systemImage: "person.badge.plus")
                    }
                    Button("שנה שם…") { renaming = true }
                }
            }
            Button {
                joining = true
            } label: {
                Label("הצטרף למשק בית עם קוד", systemImage: "ticket")
            }
            Button {
                creating = true
            } label: {
                Label("משק בית חדש", systemImage: "plus")
            }
            if let h = account.activeHousehold {
                if h.isOwner {
                    Button("מחק את משק הבית", role: .destructive) { confirmDeleteHousehold = true }
                } else {
                    Button("צא ממשק הבית", role: .destructive) { confirmLeave = true }
                }
            }
        } header: {
            Text("משק הבית")
        } footer: {
            Text("כל משק בית הוא סט נתונים נפרד (הכנסות, הוצאות, חשבונות, בני משפחה) שמשותף לכל החברים בו. אפשר להיות חבר בכמה משקי בית ולעבור ביניהם.")
        }
    }

    private var membersSection: some View {
        Section("חברים") {
            ForEach(members) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: m.title + (m.user_id == account.userID ? " (אתה)" : ""))
                        if let email = m.email, !m.display_name.isEmpty {
                            Text(verbatim: email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(m.isOwner ? "בעלים" : "חבר")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if account.activeHousehold?.isOwner == true, m.user_id != account.userID {
                        Button(role: .destructive) {
                            removing = m
                        } label: {
                            Image(systemName: "person.badge.minus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if members.isEmpty {
                Text("טוען…").foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section("החשבון") {
            RateLine(title: "מייל", value: account.email ?? "")
            HStack {
                RateLine(title: "שם", value: account.displayName.isEmpty ? "—" : account.displayName)
                Button("שנה") { editingName = true }.linkButtonStyle()
            }
            Button("שינוי סיסמה…") { changingPassword = true }
            Button("התנתק") { confirmSignOut = true }
            Button("מחיקת החשבון…", role: .destructive) { confirmDeleteAccount = true }
        }
    }

    // MARK: Actions

    private func loadMembers() async {
        guard let id = account.activeHouseholdID else { members = []; return }
        members = (try? await account.members(of: id)) ?? []
    }

    private func act(_ action: @escaping () async throws -> Void) {
        message = nil
        Task {
            do { try await action() } catch { message = UserAccount.describe(error) }
        }
    }

    private func signOut(clearDevice: Bool) {
        Task {
            await sync.signedOut(clearDevice: clearDevice)
            await account.signOut()
        }
    }

    private func deleteAccount() {
        Task {
            await sync.signedOut(clearDevice: false)
            do { try await account.deleteAccount() } catch { message = UserAccount.describe(error) }
        }
    }
}

// MARK: - Sheets

struct InviteSheet: View {
    let invite: HouseholdInvite
    let householdName: String

    private var shareText: String {
        "הוזמנת להצטרף למשק הבית ״\(householdName)״ באפליקציית מחשבון שכר.\nקוד ההזמנה: \(invite.code)\n(בתוקף עד \(invite.expiresDate.map { Fmt.date($0) } ?? "שבוע"), לשימוש אחד)\nבאפליקציה: חשבון ומשק בית ← הצטרף למשק בית עם קוד."
    }

    var body: some View {
        SheetContainer(title: "הזמנה למשק הבית", minHeight: 320, onSave: nil) {
            Section {
                Text(verbatim: invite.code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                HStack {
                    Button {
                        Platform.copy(invite.code)
                    } label: {
                        Label("העתק קוד", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    ShareLink(item: shareText) {
                        Label("שלח הזמנה", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(verbatim: "הקוד מיועד לאדם אחד ובתוקף עד " + (invite.expiresDate.map { Fmt.date($0) } ?? "שבוע") + ". מי שמצטרף רואה ועורך את כל הנתונים של משק הבית.")
            }
        }
    }
}

struct JoinHouseholdSheet: View {
    @EnvironmentObject private var account: UserAccount
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        SheetContainer(title: "הצטרפות למשק בית", saveTitle: "הצטרף", minHeight: 300, onSave: nil) {
            Section {
                FormTextField("קוד הזמנה", text: $code, prompt: Text(verbatim: "ABCD2345"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                Button("הצטרף") {
                    busy = true
                    Task {
                        do {
                            let id = try await account.acceptInvite(code: code)
                            account.activeHouseholdID = id
                            dismiss()
                        } catch {
                            self.error = UserAccount.describe(error)
                        }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 8 || busy)
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            } footer: {
                Text("אחרי ההצטרפות האפליקציה תעבור להציג את משק הבית החדש. הנתונים של משק הבית הנוכחי נשארים שמורים, ואפשר לחזור אליהם בכל רגע.")
            }
        }
    }
}

struct NewHouseholdSheet: View {
    @EnvironmentObject private var sync: ServerSync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        SheetContainer(title: "משק בית חדש", saveTitle: "צור", minHeight: 280, onSave: {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            Task { await sync.createHousehold(name: trimmed.isEmpty ? "משק בית חדש" : trimmed) }
        }) {
            Section {
                FormTextField("שם", text: $name, prompt: Text("למשל: הבית של ההורים"))
            } footer: {
                Text("משק בית חדש מתחיל ריק. הנתונים של משק הבית הנוכחי נשארים שמורים, ואפשר לעבור ביניהם בכל רגע.")
            }
        }
    }
}

struct RenameHouseholdSheet: View {
    @EnvironmentObject private var account: UserAccount
    let household: HouseholdInfo
    @State private var name = ""

    var body: some View {
        SheetContainer(title: "שם משק הבית", minHeight: 220, onSave: {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            Task { try? await account.rename(household.id, to: trimmed) }
        }) {
            FormTextField("שם", text: $name)
        }
        .onAppear { name = household.name }
    }
}

struct ChangePasswordSheet: View {
    @EnvironmentObject private var account: UserAccount
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var again = ""
    @State private var error: String?

    var body: some View {
        SheetContainer(title: "שינוי סיסמה", minHeight: 280, onSave: nil) {
            Section {
                SecureField("סיסמה חדשה (לפחות 8 תווים)", text: $password).textContentType(.newPassword)
                SecureField("שוב", text: $again).textContentType(.newPassword)
                Button("שמור") {
                    Task {
                        do { try await account.changePassword(password); dismiss() } catch { self.error = UserAccount.describe(error) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.count < 8 || password != again)
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
        }
    }
}

struct DisplayNameSheet: View {
    @EnvironmentObject private var account: UserAccount
    @State private var name = ""

    var body: some View {
        SheetContainer(title: "השם שלך", minHeight: 220, onSave: {
            Task { try? await account.updateDisplayName(name) }
        }) {
            Section {
                FormTextField("שם", text: $name)
            } footer: {
                Text("כך תופיע אצל החברים במשק הבית.")
            }
        }
        .onAppear { name = account.displayName }
    }
}

/// Which household is on screen — a small menu in the sidebar / "עוד".
struct HouseholdSwitcher: View {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var sync: ServerSync
    var onManage: () -> Void = {}

    var body: some View {
        if account.isSignedIn, let current = account.activeHousehold {
            Menu {
                ForEach(account.households) { h in
                    Button {
                        account.activeHouseholdID = h.id
                    } label: {
                        if h.id == current.id { Label(h.name, systemImage: "checkmark") } else { Text(h.name) }
                    }
                }
                Divider()
                Button("ניהול משקי בית…", action: onManage)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "house.fill")
                    Text(verbatim: current.name).lineLimit(1)
                    if sync.hasUnsyncedChanges || sync.isSyncing {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
                    } else if sync.lastError != nil {
                        Image(systemName: "exclamationmark.icloud").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .font(.callout.weight(.semibold))
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
        }
    }
}

/// Reacts to account changes and asks what to do with this device's data on the first sign-in.
struct ServerSyncLifecycle: ViewModifier {
    @EnvironmentObject private var account: UserAccount
    @EnvironmentObject private var sync: ServerSync
    @EnvironmentObject private var store: Store

    /// The app can't be used without an account; nothing to set — it closes once the user is signed in.
    private var signInRequired: Binding<Bool> {
        Binding(get: { account.didLoad && !account.isSignedIn }, set: { _ in })
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                sync.attach(store: store, account: account)
                account.start()
            }
            .onChange(of: account.userID) { _, id in
                Task { await sync.accountChanged() }
            }
            .onChange(of: account.households) { _, _ in Task { await sync.accountChanged() } }
            .onChange(of: account.activeHouseholdID) { _, _ in Task { await sync.accountChanged() } }
            #if os(iOS)
            .fullScreenCover(isPresented: signInRequired) { WelcomeView() }
            #else
            .sheet(isPresented: signInRequired) { WelcomeView() }
            #endif
            .confirmationDialog("יש כבר נתונים במכשיר הזה", isPresented: $sync.pendingLocalChoice, titleVisibility: .visible) {
                Button("העלה אותם כמשק בית חדש") { Task { await sync.resolveLocalChoice(uploadAsNew: true) } }
                Button("השתמש במשק הבית מהחשבון") { Task { await sync.resolveLocalChoice(uploadAsNew: false) } }
            } message: {
                Text("לחשבון שלך כבר יש משק בית. מה לעשות עם הנתונים שכבר נמצאים במכשיר? אם תבחר במשק הבית מהחשבון, הנתונים של המכשיר יישמרו קודם בגיבוי.")
            }
    }
}

extension View {
    func serverSyncLifecycle() -> some View { modifier(ServerSyncLifecycle()) }
}

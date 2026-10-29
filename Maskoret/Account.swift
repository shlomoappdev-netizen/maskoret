import Foundation
import SwiftUI
import Supabase

/// A household the signed-in user belongs to (one full set of the app's data, shared by its members).
struct HouseholdInfo: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var member_count: Int
    var revision: Int64
    var updated_at: String?
    var device: String?

    var isOwner: Bool { role == "owner" }
}

struct HouseholdMember: Identifiable, Codable, Equatable {
    let user_id: UUID
    var role: String
    var display_name: String
    var email: String?
    var joined_at: String?

    var id: UUID { user_id }
    var isOwner: Bool { role == "owner" }
    var title: String { display_name.isEmpty ? (email ?? "חבר") : display_name }
}

struct HouseholdInvite: Codable, Equatable {
    let code: String
    let expires_at: String

    var expiresDate: Date? { ISO8601DateFormatter.flexible(expires_at) }
}

extension ISO8601DateFormatter {
    static func flexible(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

/// The signed-in user: login, the households they belong to, and managing them.
@MainActor
final class UserAccount: ObservableObject {
    @Published private(set) var userID: UUID?
    @Published private(set) var email: String?
    @Published private(set) var displayName = ""
    @Published private(set) var households: [HouseholdInfo] = []
    /// The household whose data is on screen. Saved per device.
    @Published var activeHouseholdID: UUID? {
        didSet { UserDefaults.standard.set(activeHouseholdID?.uuidString, forKey: "activeHouseholdID") }
    }
    @Published private(set) var didLoad = false
    /// The app's owner — sees the admin screen (the server checks it again on every call).
    @Published private(set) var isAdmin = false

    var isSignedIn: Bool { userID != nil }
    var activeHousehold: HouseholdInfo? { households.first { $0.id == activeHouseholdID } }

    private var listener: Task<Void, Never>?

    init() {
        activeHouseholdID = UserDefaults.standard.string(forKey: "activeHouseholdID").flatMap(UUID.init)
    }

    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await (event, session) in supabase.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session, !(event == .initialSession && session.isExpired && session.refreshToken.isEmpty) {
                        await self.setUser(session.user)
                    } else if event == .initialSession {
                        self.clearUser()
                    }
                case .signedOut, .userDeleted:
                    self.clearUser()
                default:
                    break
                }
                self.didLoad = true
            }
        }
    }

    private func setUser(_ user: User) async {
        let changed = userID != user.id
        userID = user.id
        email = user.email
        if case .string(let name)? = user.userMetadata["display_name"] { displayName = name }
        if changed {
            await refreshHouseholds()
            isAdmin = (try? await supabase.rpc("am_i_admin").decoded(Bool.self)) ?? false
        }
    }

    private func clearUser() {
        userID = nil
        email = nil
        displayName = ""
        households = []
        isAdmin = false
    }

    // MARK: Sign up / in

    struct AlreadyRegistered: LocalizedError {
        var errorDescription: String? { "already registered" }
    }

    /// Returns true when the account still needs the code from the email.
    /// Signing up again with an email that already has an account "succeeds" without sending anything
    /// (Supabase hides which emails exist) — the returned user then has no identities, so it's reported instead.
    func signUp(email: String, password: String, name: String) async throws -> Bool {
        let response = try await supabase.auth.signUp(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password,
            data: ["display_name": .string(name.trimmingCharacters(in: .whitespaces))]
        )
        if response.session == nil, response.user.identities?.isEmpty ?? false { throw AlreadyRegistered() }
        return response.session == nil
    }

    func verifySignUp(email: String, code: String) async throws {
        try await verify(email: email, codeOrLink: code, type: .signup)
    }

    /// Accepts the 6-digit code, or the whole link from the email (copied without opening it) —
    /// until the email templates send codes, Supabase sends links.
    private func verify(email: String, codeOrLink: String, type: EmailOTPType) async throws {
        let input = codeOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.contains("token="), let hash = UserAccount.tokenHash(fromLink: input) {
            try await supabase.auth.verifyOTP(tokenHash: hash, type: type)
        } else {
            try await supabase.auth.verifyOTP(email: email.trimmingCharacters(in: .whitespaces),
                                              token: input.filter { $0.isNumber }, type: type)
        }
    }

    /// The `token` in a Supabase email link (…/auth/v1/verify?token=…&type=…) is the token hash.
    static func tokenHash(fromLink link: String) -> String? {
        let cleaned = link.replacingOccurrences(of: "&amp;", with: "&")
        guard let start = cleaned.range(of: "http") else { return nil }
        let url = String(cleaned[start.lowerBound...]).components(separatedBy: .whitespacesAndNewlines).first ?? ""
        return URLComponents(string: url)?.queryItems?.first { $0.name == "token" || $0.name == "token_hash" }?.value
    }

    func resendSignUpCode(email: String) async throws {
        try await supabase.auth.resend(email: email.trimmingCharacters(in: .whitespaces), type: .signup)
    }

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
    }

    func sendPasswordReset(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email.trimmingCharacters(in: .whitespaces))
    }

    /// The code from the "reset password" email signs the user in; then the new password is set.
    func resetPassword(email: String, code: String, newPassword: String) async throws {
        try await verify(email: email, codeOrLink: code, type: .recovery)
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    func changePassword(_ newPassword: String) async throws {
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    func updateDisplayName(_ name: String) async throws {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(80))
        try await supabase.auth.update(user: UserAttributes(data: ["display_name": .string(trimmed)]))
        if let userID {
            try await supabase.from("profiles").update(["display_name": trimmed]).eq("id", value: userID).execute()
        }
        displayName = trimmed
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        clearUser()
    }

    /// Deletes the user. Households they own alone are deleted; shared ones pass to the longest-standing member.
    func deleteAccount() async throws {
        try await supabase.rpc("delete_my_account").execute()
        try? await supabase.auth.signOut(scope: .local)
        clearUser()
    }

    // MARK: Households

    func refreshHouseholds() async {
        guard isSignedIn else { return }
        if let list = try? await supabase.rpc("my_households").decoded([HouseholdInfo].self) {
            households = list
        }
    }

    func members(of id: UUID) async throws -> [HouseholdMember] {
        try await supabase.rpc("household_members_list", params: ["hid": id]).decoded([HouseholdMember].self)
    }

    func createInvite(for id: UUID) async throws -> HouseholdInvite {
        try await supabase.rpc("create_invite", params: ["hid": id]).decoded(HouseholdInvite.self)
    }

    /// Joins with a code; returns the household's id.
    func acceptInvite(code: String) async throws -> UUID {
        struct Joined: Decodable { let id: UUID }
        let joined = try await supabase.rpc("accept_invite", params: ["p_code": code]).decoded(Joined.self)
        await refreshHouseholds()
        return joined.id
    }

    func rename(_ id: UUID, to name: String) async throws {
        struct Params: Encodable { let hid: UUID; let p_name: String }
        try await supabase.rpc("rename_household", params: Params(hid: id, p_name: name)).execute()
        await refreshHouseholds()
    }

    func leave(_ id: UUID) async throws {
        try await supabase.rpc("leave_household", params: ["hid": id]).execute()
        await refreshHouseholds()
    }

    func delete(_ id: UUID) async throws {
        try await supabase.rpc("delete_household", params: ["hid": id]).execute()
        await refreshHouseholds()
    }

    func removeMember(_ member: UUID, from id: UUID) async throws {
        struct Params: Encodable { let hid: UUID; let member: UUID }
        try await supabase.rpc("remove_member", params: Params(hid: id, member: member)).execute()
        await refreshHouseholds()
    }

    // MARK: Admin

    struct AdminOverview: Decodable {
        struct User: Decodable, Identifiable {
            struct Membership: Decodable, Hashable { let id: UUID; let name: String; let role: String }
            let id: UUID
            let email: String?
            let display_name: String
            let created_at: String
            let last_sign_in_at: String?
            let confirmed: Bool
            let households: [Membership]
        }
        struct Household: Decodable, Identifiable {
            let id: UUID
            let name: String
            let created_at: String
            let member_count: Int
            let revision: Int64
            let updated_at: String?
            let device: String?
            let size_bytes: Int?
        }
        let users: [User]
        let households: [Household]
    }

    func adminOverview() async throws -> AdminOverview {
        try await supabase.rpc("admin_overview").decoded(AdminOverview.self)
    }

    func adminDeleteUser(_ id: UUID) async throws {
        try await supabase.rpc("admin_delete_user", params: ["target": id]).execute()
    }

    func adminDeleteHousehold(_ id: UUID) async throws {
        try await supabase.rpc("admin_delete_household", params: ["hid": id]).execute()
        await refreshHouseholds()
    }

    // MARK: Errors in Hebrew

    static func describe(_ error: Error) -> String {
        let text = String(describing: error).lowercased() + " " + error.localizedDescription.lowercased()
        if let url = error as? URLError {
            return url.code == .notConnectedToInternet || url.code == .networkConnectionLost
                ? "אין חיבור לאינטרנט." : "לא ניתן להתחבר לשרת. נסה שוב בעוד רגע."
        }
        if text.contains("invalid login credentials") { return "המייל או הסיסמה לא נכונים." }
        if text.contains("email not confirmed") { return "המייל עוד לא אומת — הכנס את הקוד שקיבלת במייל." }
        if text.contains("already registered") || text.contains("already been registered") || text.contains("user_already_exists") {
            return "כבר יש חשבון עם המייל הזה — התחבר, או בחר ״שכחתי סיסמה״."
        }
        if text.contains("password") && (text.contains("at least") || text.contains("weak")) {
            return "הסיסמה קצרה או חלשה מדי — לפחות 8 תווים."
        }
        if text.contains("expired") || text.contains("otp") || text.contains("token") && text.contains("invalid") {
            return "הקוד לא נכון או שפג תוקפו. אפשר לבקש קוד חדש."
        }
        if text.contains("over_email_send_rate_limit") || text.contains("email rate limit") {
            return "נשלחו יותר מדי מיילים בשעה האחרונה, אז המייל לא נשלח. אם כבר הגיע אליך מייל קודם — השתמש בו (״יש לי כבר קוד או לינק״). אחרת נסה שוב בעוד שעה."
        }
        if text.contains("rate limit") || text.contains("too many") {
            return "יותר מדי ניסיונות. חכה כמה דקות ונסה שוב."
        }
        if text.contains("invalid or expired code") { return "קוד ההזמנה לא נכון, כבר נוצל או שפג תוקפו." }
        if text.contains("admins only") { return "רק מנהל המערכת יכול לעשות את זה." }
        if text.contains("cannot delete yourself") { return "את החשבון שלך מוחקים במסך ״חשבון ומשק בית״." }
        if text.contains("only the owner") { return "רק הבעלים של משק הבית יכול לעשות את זה." }
        if text.contains("not a member") { return "אין לך גישה למשק הבית הזה." }
        if text.contains("too many households") { return "הגעת למספר המרבי של משקי בית (20)." }
        if text.contains("invalid email") || text.contains("unable to validate email") { return "כתובת המייל לא תקינה." }
        return "הפעולה נכשלה: " + error.localizedDescription
    }
}

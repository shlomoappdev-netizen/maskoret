import SwiftUI

/// Sign in, sign up (with the code from the email), and a forgotten password.
struct AuthView: View {
    enum Mode: Hashable { case signIn, signUp, verify, forgot, reset }

    @EnvironmentObject private var account: UserAccount
    @State var mode: Mode = .signIn
    var onDone: () -> Void = {}

    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            if mode == .signIn || mode == .signUp {
                Section {
                    Picker("", selection: $mode) {
                        Text("התחברות").tag(Mode.signIn)
                        Text("חשבון חדש").tag(Mode.signUp)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            switch mode {
            case .signIn: signInSection
            case .signUp: signUpSection
            case .verify: verifySection
            case .forgot: forgotSection
            case .reset: resetSection
            }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Color.orange : Color.green)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .onChange(of: mode) { _, _ in message = nil }
    }

    // MARK: Sections

    private var emailField: some View {
        FormTextField("מייל", text: $email, prompt: Text(verbatim: "name@example.com"))
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            #endif
    }

    private var signInSection: some View {
        Section {
            emailField
            SecureField("סיסמה", text: $password)
                .textContentType(.password)
            Button("התחבר") {
                run {
                    do {
                        try await account.signIn(email: email, password: password)
                        onDone()
                    } catch where UserAccount.describe(error).contains("עוד לא אומת") {
                        // Signed up but never confirmed: send a fresh code and ask for it.
                        try? await account.resendSignUpCode(email: email)
                        mode = .verify
                        show("המייל עוד לא אומת. שלחנו קוד חדש ל-\(email) — או לחץ על הלינק שבמייל ואז ״אישרתי בלינק״.")
                    }
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty)
            Button("שכחתי סיסמה") { mode = .forgot }
                .linkButtonStyle()
        } footer: {
            Text("החשבון מאפשר לסנכרן בין המכשירים שלך ולשתף משק בית עם בני הבית.")
        }
    }

    private var signUpSection: some View {
        Section {
            FormTextField("שם", text: $name, prompt: Text("איך לקרוא לך"))
                .textContentType(.name)
            emailField
            SecureField("סיסמה (לפחות 8 תווים)", text: $password)
                .textContentType(.newPassword)
            Button("צור חשבון") {
                run {
                    let needsCode: Bool
                    do {
                        needsCode = try await account.signUp(email: email, password: password, name: name)
                    } catch is UserAccount.AlreadyRegistered {
                        mode = .signIn
                        show("כבר יש חשבון עם המייל הזה. התחבר עם הסיסמה שבחרת כשנרשמת — ואם שכחת אותה, לחץ ״שכחתי סיסמה״.", error: true)
                        return
                    }
                    if needsCode {
                        mode = .verify
                        show("שלחנו קוד בן 6 ספרות ל-\(email). הכנס אותו כאן.")
                    } else {
                        onDone()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.count < 8)
        } footer: {
            Text("הנתונים נשמרים בשרת מאובטח, ורק אתה ומי שתזמין למשק הבית שלך יכולים לראות אותם.")
        }
    }

    private var verifySection: some View {
        Section {
            Text(verbatim: "הכנס את הקוד שנשלח ל-" + email)
            FormTextField("קוד או לינק", text: $code, prompt: Text("הקוד מהמייל, או הלינק שהעתקת ממנו"))
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
            Button("אמת") { run { try await account.verifySignUp(email: email, code: code); onDone() } }
                .buttonStyle(.borderedProminent)
                .disabled(code.count < 6)
            Button("אישרתי דרך הלינק במייל — התחבר") {
                run { try await account.signIn(email: email, password: password); onDone() }
            }
            .disabled(password.isEmpty)
            Button("שלח קוד חדש") { run { try await account.resendSignUpCode(email: email); show("נשלח קוד חדש.") } }
                .linkButtonStyle()
            Button("חזרה") { mode = .signUp }
                .linkButtonStyle()
        } header: {
            Text("אימות המייל")
        } footer: {
            Text("אם במייל הגיע לינק במקום קוד: לחיצה ארוכה עליו ← ״העתק קישור״ (בלי לפתוח אותו — לינק שנפתח כבר לא עובד), והדבק כאן. או: לחץ עליו, ואז ״אישרתי דרך הלינק במייל״. כדאי לבדוק גם בספאם.")
        }
    }

    private var forgotSection: some View {
        Section {
            emailField
            Button("שלח לי קוד") {
                run {
                    try await account.sendPasswordReset(email: email)
                    mode = .reset
                    show("אם יש חשבון עם המייל הזה, נשלח אליו קוד בן 6 ספרות.")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty)
            Button("יש לי כבר קוד או לינק מהמייל") { mode = .reset }
                .linkButtonStyle()
                .disabled(email.isEmpty)
            Button("חזרה להתחברות") { mode = .signIn }
                .linkButtonStyle()
        } header: {
            Text("שכחתי סיסמה")
        }
    }

    private var resetSection: some View {
        Section {
            FormTextField("קוד או לינק", text: $code, prompt: Text("הקוד מהמייל, או הלינק שהעתקת ממנו"))
                .textContentType(.oneTimeCode)
            SecureField("סיסמה חדשה (לפחות 8 תווים)", text: $newPassword)
                .textContentType(.newPassword)
            Button("שמור סיסמה חדשה") {
                run { try await account.resetPassword(email: email, code: code, newPassword: newPassword); onDone() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.count < 6 || newPassword.count < 8)
            Button("חזרה") { mode = .forgot }
                .linkButtonStyle()
        } header: {
            Text(verbatim: "סיסמה חדשה ל-" + email)
        } footer: {
            Text("אם במייל הגיע לינק ולא קוד: לחיצה ארוכה עליו ← ״העתק קישור״, והדבק אותו בשדה הקוד. אל תפתח את הלינק — אחרי שהוא נפתח הוא כבר לא עובד, וצריך לבקש מייל חדש.")
        }
    }

    // MARK: Helpers

    private func show(_ text: String, error: Bool = false) {
        message = text
        isError = error
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do {
                try await action()
            } catch {
                show(UserAccount.describe(error), error: true)
            }
            busy = false
        }
    }
}

/// Signing in is required: shown over the app until the user is signed in.
/// The data already on the device isn't touched — after signing in it's uploaded to the account (or kept as a backup).
struct WelcomeView: View {
    var body: some View {
        // The form scrolls by itself; the header stays on top.
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "house.and.flag.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 24)
                Text("ברוך הבא למחשבון שכר")
                    .font(.title.weight(.bold))
                Text("כדי להשתמש באפליקציה צריך חשבון. הנתונים נשמרים בשרת מאובטח, מסתנכרנים בין המחשב לטלפון, ואפשר לשתף משק בית עם בני הבית. נתונים שכבר יש במכשיר הזה לא נמחקים — אחרי ההתחברות הם עולים לחשבון שלך.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            AuthView()
        }
        #if os(macOS)
        .frame(width: 520, height: 700)
        #endif
        .interactiveDismissDisabled()
        .hebrew()
    }
}
